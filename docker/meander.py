#!/usr/bin/env python3
"""Run one CPU-only, teacher-free Meander island with persistent artifacts."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import time


REPO = Path(__file__).resolve().parents[1]
OUTPUT = Path("/run/bes")
PORT = 8082
SBCL = [
    "sbcl", "--dynamic-space-size", "4096", "--noinform", "--non-interactive",
    "--eval", "(require :asdf)", "--eval", "(asdf:load-system :cl-tpg)",
]
# Persist exactly the status events used by the ordinary BES monitor.
TELEMETRY = """
(lambda (message)
  (when (or (search ":TYPE :FITNESS" message)
            (search ":TYPE :MESSAGE" message)
            (search ":TYPE :ERROR" message))
    (write-line message)
    (finish-output)))
"""


def send(message):
    with socket.create_connection(("127.0.0.1", PORT), timeout=2) as client:
        client.sendall((message.strip() + "\n").encode("utf-8"))


def smoke():
    subprocess.run(SBCL + ["--load", str(REPO / "tests/controller.lisp")], check=True)
    subprocess.run(SBCL + ["--load", str(REPO / "tests/cardiff-action-space.lisp")],
                   check=True)


def train(island, population, seed, peers):
    os.environ["BES_ISLAND_IP"] = str(peers[island - 1])
    checkpoints = OUTPUT / "checkpoints"
    checkpoints.mkdir()
    request = f"""(:type :start-search :mode :official-online
 :gym-environment-name "Cage2-cardiff-meander-100-v0" :dataset-name :none
 :checkpoint-directory {json.dumps(str(checkpoints) + "/")}
 :num-observations 62 :num-actions 36 :instruction-set-profile :reduced-eq
 :read-only-register-profile :cage2-categorical-v1 :instruction-mutation-mode :field-local
 :effective-aware-mutation-enabled :enabled :decoy-order-mode :fixed :cage2-opening-mode :fixed
 :teacher-forcing-rollout-mode :teacher :teacher-backend :heuristic
 :population-size {population} :init-num-learners 3 :max-num-learners 32
 :p-add 0.2d0 :p-del 0.1d0 :p-mut 0.5d0 :p-act 0.2d0 :p-swap 0.1d0
 :gap 0.5d0 :init-program-size 100 :max-program-size 256
 :p-add-instr 0.9d0 :p-del-instr 0.5d0 :p-swap-instrs 1.0d0
 :p-mut-constant 0.5d0 :p-mut-constant-sign 0.1d0
 :migration-interval 50 :batch-size 1000 :online-fitness-episodes 1
 :hamming-space-enabled :disabled :hamming-dataset-name :none
 :recurrent-policy-enabled :disabled :seed {seed})
"""
    (OUTPUT / "start-search.sexp").write_text(request)
    (OUTPUT / "input-sha256.txt").write_text(
        Path("/opt/bes-source-manifest.txt").read_text()
    )
    island_map = " ".join(f"({json.dumps(str(ip))} . {index})"
                          for index, ip in enumerate(peers, 1))
    neighbors = sorted({(island - 2) % len(peers) + 1,
                        island % len(peers) + 1} - {island})
    topology = f"(({island} {' '.join(map(str, neighbors))}))"
    command = SBCL + [
        "--eval", f"(setf cl-tpg::*server-port* {PORT} "
                  f"cl-tpg::*islands* '({island_map}) "
                  f"cl-tpg::*topology* '{topology})",
        "--eval", f"(setf (symbol-function 'cl-tpg::notify-telemetry) {TELEMETRY})",
        "--eval", "(cl-tpg:start-server)",
        "--eval", "(loop (sleep 3600))",
    ]
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    log = OUTPUT / "server.log"
    print(f"Fresh Cardiff-action Meander island {island}, {population} roots, seed {seed}, log {log}", flush=True)
    with log.open("xb") as writer:
        # Keep the supervisor separate from the Lisp/bridge process group so a
        # docker stop can send the native stop request before terminating Lisp.
        server = subprocess.Popen(command, cwd=REPO, stdout=writer,
                                  stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = time.monotonic() + 60
            while not stopping:
                if server.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError(f"BES listener failed to start. See {log}.")
                try:
                    send(request)
                    break
                except OSError:
                    time.sleep(0.5)
            with log.open("r", errors="replace") as reader:
                while not stopping:
                    for line in reader:
                        print(line, end="", flush=True)
                        if "[BES SEARCH FAILURE]" in line or "provided are invalid" in line:
                            raise RuntimeError(f"Meander search failed. See {log}.")
                    if server.poll() is not None:
                        raise RuntimeError(f"BES exited with status {server.returncode}.")
                    time.sleep(1)
        finally:
            if server.poll() is None:
                try:
                    send("(:type :stop-search)")
                except OSError:
                    pass
                with log.open("r", errors="replace") as reader:
                    reader.seek(0, 2)
                    deadline = time.monotonic() + 35
                    while server.poll() is None and time.monotonic() < deadline:
                        if "Search stopped on island" in reader.read():
                            break
                        time.sleep(0.5)
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("smoke", "train"))
    parser.add_argument("--island", type=int, default=1)
    parser.add_argument("--population", type=int, default=160)
    parser.add_argument("--seed", type=int, default=153)
    parser.add_argument("--peers", type=ipaddress.IPv4Address, nargs="+",
                        default=[ipaddress.IPv4Address("127.0.0.1")])
    args = parser.parse_args()
    if args.island < 1 or args.population < 2 or args.seed < 0:
        parser.error("island and population must be positive, and seed nonnegative")
    if args.island > len(args.peers) or len(args.peers) != len(set(args.peers)):
        parser.error("the peer list must contain one unique address per island")
    OUTPUT.mkdir(exist_ok=True, parents=True)
    if any(OUTPUT.iterdir()):
        raise SystemExit(f"Use an empty output directory at {OUTPUT}")
    if args.mode == "smoke":
        smoke()
    else:
        train(args.island, args.population, args.seed, args.peers)


if __name__ == "__main__":
    main()

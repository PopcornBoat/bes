#!/usr/bin/env python3
"""Start four independent BES searches under the ranked Decoy contract."""
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parent.parent
VENV = Path("/home/hardison/venv-base/cage2_bridge/.venv/bin")
SOURCE = REPO/"validated-checkpoints/bline-v14/bline-62-36-v14.lisp"
V14 = "0d023ad8ad0f8191751e2a205b09c8bc5d3a15c2f17e1ca604ca0a3830fd0aa4"
PORTS = (8091,8092,8093,8094)
SEEDS = (153,4011,6017,7019)
LOG_TELEMETRY = """(let ((send (symbol-function 'cl-tpg::notify-telemetry)))
  (setf (symbol-function 'cl-tpg::notify-telemetry)
        (lambda (message)
          (when (or (search ":TYPE :FITNESS" message) (search ":TYPE :MESSAGE" message))
            (format t "~&~A~%" message)
            (finish-output))
          (funcall send message))))"""

def request(checkpoint_dir, seed):
    return f"""(:type :resume-search :mode :official-online
 :gym-environment-name "Cage2-b_line-100-v0" :dataset-name :none
 :best-team-path {json.dumps(str(SOURCE))} :checkpoint-directory {json.dumps(str(checkpoint_dir)+"/")}
 :num-observations 62 :num-actions 36 :instruction-set-profile :reduced-eq
 :read-only-register-profile :cage2-categorical-v1 :instruction-mutation-mode :field-local
 :effective-aware-mutation-enabled :enabled :decoy-order-mode :fixed :cage2-opening-mode :fixed
 :teacher-forcing-rollout-mode :teacher :teacher-backend :heuristic
 :population-size 80 :init-num-learners 3 :max-num-learners 32
 :p-add 0.2d0 :p-del 0.1d0 :p-mut 0.5d0 :p-act 0.2d0 :p-swap 0.1d0
 :gap 0.5d0 :init-program-size 100 :max-program-size 256
 :p-add-instr 0.9d0 :p-del-instr 0.5d0 :p-swap-instrs 1.0d0
 :p-mut-constant 0.5d0 :p-mut-constant-sign 0.1d0
 :migration-interval 50 :batch-size 1000 :online-fitness-episodes 1
 :hamming-space-enabled :disabled :hamming-dataset-name :none
 :recurrent-policy-enabled :disabled :seed {seed})
"""

def connect(port):
    return socket.create_connection(("127.0.0.1",port),timeout=1)

def send(port,message):
    with connect(port) as connection:
        connection.sendall((message.strip()+"\n").encode())

def status(folder, port, process):
    with (folder/"server.log").open("rb") as handle:
        handle.seek(max(0,handle.seek(0,2)-65536))
        data=handle.read().decode(errors="replace")
    events=re.findall(r'\(:TYPE :FITNESS.*?:GENERATION\s+(\d+)',data,re.DOTALL)
    fitness=re.findall(r':HISTORICAL-BEST\s+"([^"]+)"',data)
    failures=[line for line in data.splitlines() if "[BES SEARCH FAILURE]" in line]
    tail=f"gen={events[-1]} hist={fitness[-1]}" if events and fitness else "initializing"
    if failures:
        tail=failures[-1]
    return f"{port} pid={process.pid} state={process.poll() if process.poll() is not None else 'running'} {tail}"

def run(out):
    assert hashlib.sha256(SOURCE.read_bytes()).hexdigest()==V14
    cores=sorted(os.sched_getaffinity(0))
    assert len(cores)>=len(PORTS)
    out.mkdir(parents=True,exist_ok=True)
    env=dict(os.environ,OPENBLAS_NUM_THREADS="1",OMP_NUM_THREADS="1")
    env["PATH"]=str(VENV)+os.pathsep+env["PATH"]
    env["CL_SOURCE_REGISTRY"]=f'(:source-registry (:directory "{REPO}/") :ignore-inherited-configuration)'
    processes=[]
    def stop(_signum,_frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM,stop)
    try:
        for i,(port,seed) in enumerate(zip(PORTS,SEEDS)):
            with socket.socket() as probe:
                probe.bind(("127.0.0.1",port))
            folder=out/f"island-{i+1}"
            folder.mkdir()
            checkpoint_dir=folder/"checkpoints"
            checkpoint_dir.mkdir()
            payload=request(checkpoint_dir,seed)
            (folder/"resume-search.sexp").write_text(payload)
            cpus=",".join(str(c) for c in cores[i::len(PORTS)])
            cmd=["taskset","-c",cpus,"sbcl","--dynamic-space-size","2048","--noinform","--non-interactive",
                 "--eval","(require :asdf)","--eval","(asdf:load-system :cl-tpg)",
                 "--eval",f"(setf cl-tpg::*server-port* {port})",
                 "--eval",LOG_TELEMETRY,"--eval","(cl-tpg:start-server)","--eval","(loop (sleep 3600))"]
            with (folder/"server.log").open("w") as log:
                child=subprocess.Popen(cmd,cwd=REPO,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            processes.append((folder,port,child,payload))
        for folder,port,child,payload in processes:
            deadline=time.monotonic()+90
            while True:
                if child.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError(f"BES startup failed for {port}; see {folder}/server.log")
                try:
                    send(port,payload)
                    break
                except OSError:
                    time.sleep(1)
        (out/"RUNNING").write_text("Ranked Decoy warm starts requested on 8091–8094.\n")
        while True:
            lines=[status(folder,port,child) for folder,port,child,_ in processes]
            print("new  "+" | ".join(lines),flush=True)
            if not any(child.poll() is None for _,_,child,_ in processes):
                break
            time.sleep(15)
    finally:
        for _,port,child,_ in processes:
            if child.poll() is None:
                try:
                    send(port,"(:type :stop-search)")
                except OSError:
                    pass
                child.terminate()
        for _,_,child,_ in processes:
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()

if __name__=="__main__":
    run(Path(sys.argv[1]).resolve())

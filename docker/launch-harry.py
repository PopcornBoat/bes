#!/usr/bin/env python3
"""Launch four fresh Cardiff-action islands alongside the existing Meander run."""
import argparse
import os
from pathlib import Path
import subprocess

EXPERIMENT = "meander-cardiff-action-space"
NETWORK = "bes-cardiff-ring"
PEERS = [f"172.28.97.{n}" for n in range(11, 15)]
# Share the second SMT thread of eight physical cores. Spread the extra
# load across both NUMA sockets while leaving the existing run's binding intact.
CPUS = ["24,26", "36,38", "25,27", "37,39"]
SEEDS = [153, 4011, 6017, 7019]

def docker(*args):
    return subprocess.run(["docker", *args], check=True, text=True,
                          stdout=subprocess.PIPE).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--image", default="bes-meander:cardiff-action-space")
    parser.add_argument("--population", type=int, default=160)
    args = parser.parse_args()
    output = args.output.resolve()
    uid = int(os.environ.get("SUDO_UID", os.getuid()))
    gid = int(os.environ.get("SUDO_GID", os.getgid()))
    output.mkdir()
    os.chown(output, uid, gid)
    docker("network", "create", "--internal", "--subnet", "172.28.97.0/24", NETWORK)
    started = []
    try:
        for index, (ip, cpus, seed) in enumerate(zip(PEERS, CPUS, SEEDS)):
            island = str(index + 1)
            name = f"bes-cardiff-{island}"
            directory = output / f"island-{island}"
            directory.mkdir()
            os.chown(directory, uid, gid)
            container_id = docker(
                "run", "-d", "--name", name, "--label", f"bes.experiment={EXPERIMENT}",
                "--user", f"{uid}:{gid}", "--env", "HOME=/tmp",
                "--network", NETWORK, "--ip", ip, "--cpuset-cpus", cpus,
                "--cpuset-mems", str(index // 2), "--cpu-shares", "512", "--memory", "10g", "--stop-timeout", "50",
                "--log-opt", "max-size=20m", "--log-opt", "max-file=3",
                "--mount", f"type=bind,src={directory},dst=/run/bes", args.image,
                "train", "--island", island, "--population", str(args.population),
                "--seed", str(seed), "--peers", *PEERS,
            )
            started.append(name)
            print(f"{name} {container_id[:12]} cpu={cpus} seed={seed}", flush=True)
    except BaseException:
        if started:
            subprocess.run(["docker", "stop", *started], check=False)
        raise


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Frozen three-lane closed-loop offspring nomination pilot; no promotion."""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import random
import re
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def quote(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--source-run", type=Path, default=Path(
        "/home/hardison/bes-artifacts/runtime/stratified-controller-repair-20261107/search"))
    parser.add_argument("--seed-root", type=int, default=8112026)
    parser.add_argument("--generator-root", type=int, default=830118)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    source = args.source_run.resolve()
    parent = source / "inputs/parent.lisp"
    traces = source / "discovery/traces"
    source_manifest = json.loads((source / "manifest.json").read_text())
    if digest(parent) != source_manifest["input_sha256"][source_manifest["parent"]]:
        parser.error("Frozen parent does not match source manifest")
    trace_files = sorted(traces.glob("*-incumbent.sexp"))
    if not trace_files:
        parser.error("No genuine incumbent discovery traces")
    seed_rng = random.Random(args.seed_root)
    excluded = {153, 42, 2026, 42197, 68329, 91583, 147179}
    runtime = Path("/home/hardison/bes-artifacts/runtime")
    for path in runtime.rglob("seeds.sexp"):
        excluded.update(map(int, re.findall(r"\d+", path.read_text())))
    for path in runtime.glob("*/manifest.json"):
        try:
            previous = json.loads(path.read_text())
        except (ValueError, OSError):
            continue
        for key in ("discovery_seeds", "screen_seeds", "confirmation_seeds", "evaluation_seeds"):
            if isinstance(previous.get(key), list):
                excluded.update(x for x in previous[key] if isinstance(x, int))
    n_screen, n_confirm, n_lane = (1, 1, 1) if args.smoke else (5, 20, 4)
    generated = []
    while len(generated) < n_screen + n_confirm:
        value = seed_rng.randrange(2**32)
        if value not in excluded:
            excluded.add(value)
            generated.append(value)
    if (output / "manifest.json").exists():
        old = json.loads((output / "manifest.json").read_text())
        generated = old["screen_seeds"] + old["confirmation_seeds"]
    trace_hash = hashlib.sha256()
    for path in trace_files:
        trace_hash.update(path.name.encode())
        trace_hash.update(path.read_bytes())
    files = sorted(repo.glob("*.lisp")) + [
        repo / "cl-tpg.asd", repo / "scripts/privileged-state.py", Path(__file__).resolve()]
    code_hashes = {str(p.relative_to(repo)): digest(p) for p in files}
    cyborg = Path(importlib.util.find_spec("CybORG").origin).parent
    environment_hash = hashlib.sha256()
    for path in sorted(cyborg.rglob("*.py")):
        environment_hash.update(str(path.relative_to(cyborg)).encode())
        environment_hash.update(path.read_bytes())
    bridge = Path(importlib.util.find_spec("cage2_bridge.cage2").origin)
    config = {
        "protocol": "closed-loop-nomination-pilot-v1", "smoke": args.smoke,
        "parent": str(parent), "parent_sha256": digest(parent),
        "source_run": str(source), "trace_count": len(trace_files),
        "trace_sha256": trace_hash.hexdigest(), "code_sha256": code_hashes,
        "cyborg_sha256": environment_hash.hexdigest(), "bridge_sha256": digest(bridge),
        "seed_root": args.seed_root, "generator_root": args.generator_root,
        "screen_seeds": generated[:n_screen], "confirmation_seeds": generated[n_screen:],
        "per_lane": n_lane, "lanes": ["coverage", "failure", "random"],
        "generator": {"gate_atoms": 2, "margin": 250, "insertion": "terminal",
                      "max_groups": 24, "min_independent_group_exposure": 2},
        "early_reject": "paired Op_Server0 regression OR n>=5 and mean_delta+2*sample_SE < -10",
        "confirmation_selection": "first surviving ID in pre-outcome independent uniform lottery",
        "fresh_positive": "20 episodes; mean_delta-2.093*sample_SE>0; no protected-host regression; unadjusted exploratory",
        "promotion": "not attempted; existing production thresholds unchanged",
        "nominal_max_transitions": (3*n_lane+1)*n_screen*100 + 4*n_confirm*100,
        "baseline_identity": "same frozen v9, official Meander-100, fixed opening and meander fixed decoy Controller, stateless 62 inputs",
        "git_commit": subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip(),
    }
    output.mkdir(parents=True, exist_ok=True)
    with (output / ".lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("Another process owns this pilot")
        manifest = output / "manifest.json"
        if manifest.exists():
            old = json.loads(manifest.read_text())
            if {k: v for k, v in old.items() if k != "git_commit"} != {
                    k: v for k, v in config.items() if k != "git_commit"}:
                parser.error("Configuration or inputs changed; choose a new output")
            if (output / "summary.sexp").exists():
                print("Pilot already complete; no new environment interactions\ndone")
                return 0
        else:
            if any(p.name != ".lock" for p in output.iterdir()):
                parser.error("Nonempty output lacks a frozen manifest")
            manifest.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")
        frozen = output / "parent.lisp"
        if not frozen.exists():
            frozen.write_bytes(parent.read_bytes())
            frozen.chmod(0o444)
        if digest(frozen) != digest(parent):
            parser.error("Frozen parent changed")
        request = output / "request.sexp"
        request.write_text(
            f"(:parent-path {quote(frozen)} :trace-directory {quote(traces)} :output {quote(output)} "
            f":screen-seeds ({' '.join(map(str,config['screen_seeds']))}) "
            f":confirmation-seeds ({' '.join(map(str,config['confirmation_seeds']))}) "
            f":per-lane {n_lane} :generator-root {args.generator_root})\n")
        command = ["/usr/bin/sbcl", "--dynamic-space-size", "4096", "--noinform",
                   "--non-interactive", "--eval", "(require :asdf)",
                   "--eval", "(asdf:load-system :cl-tpg)"]
        for name in ("official-counterfactual-pilot.lisp", "privileged-search.lisp",
                     "structural-opportunity-audit.lisp", "closed-loop-nomination-pilot.lisp"):
            command += ["--load", str(repo / name)]
        command += ["--eval", "(apply #'cl-tpg::run-closed-loop-nomination-pilot "
                    f"(cl-tpg::read-readable-object {quote(request)}))"]
        env = os.environ.copy()
        env["PATH"] = "/home/hardison/venv-base/cage2_bridge/.venv/bin:" + env.get("PATH", "")
        env["CL_SOURCE_REGISTRY"] = f'(:source-registry (:directory "{repo}/") :ignore-inherited-configuration)'
        return subprocess.run(command, cwd=repo, env=env).returncode


if __name__ == "__main__":
    sys.exit(main())

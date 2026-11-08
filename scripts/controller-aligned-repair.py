#!/usr/bin/env python3
"""Run bounded C13 counterfactual measurement and controller-aligned refinement."""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import random
from pathlib import Path
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def quote(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--search", type=Path, default=Path(
        "/home/hardison/bes-artifacts/runtime/privileged-meander-evidence-20261107/search"))
    parser.add_argument("--screen", type=Path, default=Path(
        "/home/hardison/bes-artifacts/runtime/privileged-evidence-fresh-screen-20261107"))
    parser.add_argument("--max-cases", type=int, default=24)
    parser.add_argument("--max-candidates", type=int, default=12)
    parser.add_argument("--extra-queries", type=int, default=24)
    parser.add_argument("--fresh-episodes", type=int, default=0,
                        help="Collect new C13/v9 trajectories instead of reusing screen traces")
    parser.add_argument("--discovery-seed-root", type=int, default=291107)
    parser.add_argument("--evaluation-seeds", default="153,42197,68329,91583,147179,2586165321,2517123629")
    args = parser.parse_args()
    if (min(args.max_cases, args.max_candidates) < 1 or args.extra_queries < 0
            or args.fresh_episodes < 0 or args.fresh_episodes > 1000):
        parser.error("Invalid experiment budget")
    try:
        seeds = [int(x) for x in args.evaluation_seeds.split(",")]
    except ValueError:
        parser.error("Invalid seed list")
    if len(seeds) != len(set(seeds)) or any(x < 0 or x >= 2**32 for x in seeds):
        parser.error("Seeds must be unique uint32 values")
    if not seeds:
        parser.error("At least one evaluation seed is required")
    repo = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    search = args.search.resolve()
    screen = args.screen.resolve()
    parent = search / "source.lisp"
    repair = search / "round-1/candidate-13.lisp"
    spec = search / "round-1/candidate-13-result.sexp"
    screen_plan = json.loads((screen / "plan.json").read_text())
    if digest(parent) != screen_plan["checkpoint_sha256"]["incumbent"] or digest(repair) != screen_plan["checkpoint_sha256"]["c13"]:
        parser.error("Input graphs do not match the frozen screened policies")
    # Disjoint from the old screening and discovery roots. Persist the exact
    # new block; its outcomes are discovery, never confirmation evidence.
    excluded = set(seeds) | {153, 42, 2026}
    excluded.update(int(x) for x in (screen / "seeds.sexp").read_text().strip().strip("()").split())
    discovery_seeds = []
    generator = random.Random(args.discovery_seed_root)
    while len(discovery_seeds) < args.fresh_episodes:
        value = generator.randrange(2**32)
        if value not in excluded:
            excluded.add(value)
            discovery_seeds.append(value)
    source_files = list(repo.glob("*.lisp")) + [repo / "cl-tpg.asd",
                    repo / "scripts/privileged-state.py", Path(__file__).resolve()]
    code_hashes = {str(p.relative_to(repo)): digest(p) for p in sorted(source_files)}
    cyborg = Path(importlib.util.find_spec("CybORG").origin).parent
    simulator = hashlib.sha256()
    for path in sorted(cyborg.rglob("*.py")):
        simulator.update(str(path.relative_to(cyborg)).encode())
        simulator.update(path.read_bytes())
    bridge = Path(importlib.util.find_spec("cage2_bridge.cage2").origin)
    environment_signature = hashlib.sha256((simulator.hexdigest() + digest(bridge) +
        code_hashes["controller.lisp"] + code_hashes["team.lisp"]).encode()).hexdigest()
    trace_hash = hashlib.sha256()
    for path in sorted((screen / "traces").glob("*.sexp")):
        trace_hash.update(path.name.encode())
        trace_hash.update(path.read_bytes())
    config = {
        "protocol": "controller-aligned-repair-v2",
        "parent": str(parent), "repair": str(repair), "spec": str(spec),
        "input_sha256": {str(p): digest(p) for p in [parent, repair, spec, screen / "seeds.sexp", screen / "plan.json"]},
        "code_sha256": code_hashes, "trace_sha256": trace_hash.hexdigest(),
        "environment_signature": environment_signature,
        "max_cases": args.max_cases, "max_candidates": args.max_candidates,
        "extra_queries": args.extra_queries, "evaluation_seeds": seeds,
        "screen": str(screen),
        "fresh_episodes": args.fresh_episodes,
        "discovery_seed_root": args.discovery_seed_root,
        "discovery_seeds": discovery_seeds,
        "sampling": "both behavior trajectories; all actual disagreements; observation/path/action/access/phase strata; max 2 points per seed",
        "data_roles": "Existing screen and nominated trajectories are discovery evidence; future confirmation must use fresh seeds.",
        "git_commit": subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip(),
    }
    output.mkdir(parents=True, exist_ok=True)
    with (output / ".lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("Another process owns this experiment")
        manifest = output / "manifest.json"
        if manifest.exists():
            previous = json.loads(manifest.read_text())
            if {k: v for k, v in previous.items() if k != "git_commit"} != {k: v for k, v in config.items() if k != "git_commit"}:
                parser.error("Input/configuration changed; choose a new experiment directory")
            if (output / "summary.sexp").exists():
                print("Experiment already complete; results are in summary.sexp\ndone")
                return 0
        else:
            if any(x.name != ".lock" for x in output.iterdir()):
                parser.error("Nonempty output has no experiment manifest")
            manifest.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")
        frozen = output / "inputs"
        frozen.mkdir(exist_ok=True)
        frozen_inputs = {}
        for role, original in (("parent", parent), ("repair", repair), ("spec", spec)):
            path = frozen / (role + ".lisp")
            if not path.exists():
                path.write_bytes(original.read_bytes())
                path.chmod(0o444)
            if digest(path) != digest(original):
                parser.error("Frozen experiment input changed")
            frozen_inputs[role] = path
        request = output / "request.sexp"
        request.write_text(
            f"(:parent-path {quote(frozen_inputs['parent'])} :repair-path {quote(frozen_inputs['repair'])} :spec-path {quote(frozen_inputs['spec'])} "
            f":screen-directory {quote(screen)} :output {quote(output)} "
            f":environment-signature {quote(environment_signature)} "
            f":max-cases {args.max_cases} :max-candidates {args.max_candidates} "
            f":extra-queries {args.extra_queries} :evaluation-seeds ({' '.join(map(str,seeds))}) "
            f":discovery-seeds ({' '.join(map(str,discovery_seeds))}))\n")
        env = os.environ.copy()
        env["PATH"] = "/home/hardison/venv-base/cage2_bridge/.venv/bin:" + env.get("PATH", "")
        env["CL_SOURCE_REGISTRY"] = f'(:source-registry (:directory "{repo}/") :ignore-inherited-configuration)'
        command = ["/usr/bin/sbcl", "--dynamic-space-size", "4096", "--noinform", "--non-interactive",
                   "--eval", "(require :asdf)", "--eval", "(asdf:load-system :cl-tpg)"]
        for name in ("official-counterfactual-pilot.lisp", "privileged-search.lisp", "controller-aligned-credit.lisp"):
            command += ["--load", str(repo / name)]
        command += ["--eval", "(apply #'cl-tpg::run-controller-aligned-repair "
                    f"(cl-tpg::read-readable-object {quote(request)}))"]
        return subprocess.run(command, cwd=repo, env=env).returncode


if __name__ == "__main__":
    sys.exit(main())

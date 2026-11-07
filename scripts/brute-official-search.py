#!/usr/bin/env python3
"""Bounded fixed-seed search using official transitions and private diagnostics."""
import argparse
import csv
import fcntl
import hashlib
import json
import importlib.util
import os
import subprocess
import sys
from pathlib import Path


def integers(text):
    try:
        values = [int(x) for x in text.split(",")]
    except ValueError as exc:
        raise argparse.ArgumentTypeError("Expected comma-separated integers") from exc
    if not values or len(values) != len(set(values)):
        raise argparse.ArgumentTypeError("Values must be nonempty and unique")
    return values


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def lisp_string(text):
    return '"' + str(text).replace("\\", "\\\\").replace('"', '\\"') + '"'


def report(output):
    lines = ["# Fixed-seed official brute search", "",
             "These are discovery-set measurements. Independent fresh-seed validation is required.",
             ""]
    for directory in sorted(output.glob("round-*")):
        path = directory / "interventions.tsv"
        if not path.exists():
            continue
        with path.open() as handle:
            rows = list(csv.DictReader(handle, delimiter="\t"))
        lines += [f"## {directory.name}", "",
                  f"Completed intervention comparisons: {len(rows)}", "",
                  "| Seed | Step (zero based) | Semantic index | Return delta |",
                  "|---|---|---|---|"]
        for row in rows[:20]:
            lines.append(f"| {row['seed']} | {row['step']} | {row['action']} | {float(row['delta']):+.4f} |")
        lines += ["", "Gate definitions and full-policy candidate results are in round-summary.sexp.",
                  "Baseline/positive traces include pre/post hidden state, Controller state and policy observations.", ""]
    (output / "report.md").write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--red", choices=("meander", "b_line"), default="meander")
    parser.add_argument("--horizon", type=int, choices=(30, 50, 100), default=100)
    parser.add_argument("--seeds", type=integers, default=[153, 42197, 68329])
    parser.add_argument("--steps", type=integers)
    parser.add_argument("--prior-evidence", type=Path,
                        help="Reuse first-round interventions from the same frozen source/environment")
    parser.add_argument("--actions", type=integers, default=list(range(36)))
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--max-branches", type=int, default=12000,
                        help="Maximum executable state/action interventions per round")
    parser.add_argument("--max-candidates", type=int, default=24)
    parser.add_argument("--top-opportunities", type=int, default=4)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    checkpoint = args.checkpoint or repo / "validated-checkpoints" / (
        "meander-v9/meander-62-36-v9.lisp" if args.red == "meander"
        else "bline-v14/bline-62-36-v14.lisp")
    checkpoint = checkpoint.resolve()
    args.steps = args.steps if args.steps is not None else list(range(3, args.horizon))
    if (any(x < 0 or x >= 2**32 for x in args.seeds)
            or any(x < 3 or x >= args.horizon for x in args.steps)
            or any(x < 0 or x >= 36 for x in args.actions)
            or min(args.rounds, args.max_branches, args.max_candidates, args.top_opportunities) <= 0):
        parser.error("Invalid budget, seed, step or action index")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with (output / ".lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("This output directory already has a running search")
        sources = ["privileged-search.lisp", "official-counterfactual-pilot.lisp",
                   "active-specialist-incubation.lisp", "scripts/privileged-state.py",
                   "scripts/brute-official-search.py"]
        sources += sorted(f.name for f in repo.glob("*.lisp") if f.name not in sources)
        sources += ["cl-tpg.asd"]
        config = {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()}
        bridge_source = Path(importlib.util.find_spec("cage2_bridge.cage2").origin)
        cyborg_root = Path(importlib.util.find_spec("CybORG").origin).parent
        simulator_hash = hashlib.sha256()
        for module in sorted(cyborg_root.rglob("*.py")):
            simulator_hash.update(str(module.relative_to(cyborg_root)).encode())
            simulator_hash.update(module.read_bytes())
        config.update(bridge_sha256=sha(bridge_source),
                      cyborg_source_sha256=simulator_hash.hexdigest(),
                      checkpoint=str(checkpoint), checkpoint_sha256=sha(checkpoint),
                      source_sha256={name: sha(repo / name) for name in sources},
                      commit=subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"],
                                                     text=True).strip())
        if args.prior_evidence:
            args.prior_evidence = args.prior_evidence.resolve()
            prior_manifest = args.prior_evidence.parent / "manifest.json"
            previous = json.loads(prior_manifest.read_text())
            for key in ("checkpoint_sha256", "bridge_sha256", "cyborg_source_sha256", "red", "horizon"):
                if previous.get(key) != config.get(key):
                    parser.error(f"Prior evidence does not match current {key}")
            evidence_hash = hashlib.sha256()
            for path in sorted(args.prior_evidence.glob("trial-*.sexp")):
                evidence_hash.update(path.name.encode())
                evidence_hash.update(path.read_bytes())
            config["prior_evidence_sha256"] = evidence_hash.hexdigest()
            config["prior_evidence"] = str(args.prior_evidence)
        manifest = output / "manifest.json"
        if manifest.exists():
            previous = json.loads(manifest.read_text())
            if {k: v for k, v in previous.items() if k != "commit"} != {
                    k: v for k, v in config.items() if k != "commit"}:
                parser.error("Resume configuration or input hashes changed. Use a new output directory.")
        else:
            if any(x.name != ".lock" for x in output.iterdir()):
                parser.error("Output directory contains files without a search manifest")
            manifest.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")
            (output / "source.lisp").write_bytes(checkpoint.read_bytes())
        if sha(output / "source.lisp") != config["checkpoint_sha256"]:
            parser.error("Frozen source checkpoint has changed")
        request = {
            "checkpoint": str(output / "source.lisp"), "output": str(output),
            "environment": f"Cage2-{args.red}-{args.horizon}-v0",
            "seeds": args.seeds, "steps": args.steps, "actions": args.actions,
            "prior-evidence": str(args.prior_evidence) if args.prior_evidence else None,
            "rounds": args.rounds, "max-branches": args.max_branches,
            "max-candidates": args.max_candidates, "top-opportunities": args.top_opportunities,
        }
        def encode(value):
            if value is None:
                return "nil"
            if isinstance(value, list):
                return "(" + " ".join(map(str, value)) + ")"
            return str(value) if isinstance(value, int) else lisp_string(value)
        request_path = output / "request.sexp"
        request_path.write_text("(" + "\n ".join(f":{key} {encode(value)}"
                                                 for key, value in request.items()) + ")\n")
        env = os.environ.copy()
        env["CL_SOURCE_REGISTRY"] = f'(:source-registry (:directory "{repo}/") :ignore-inherited-configuration)'
        env["PATH"] = "/home/hardison/venv-base/cage2_bridge/.venv/bin:" + env.get("PATH", "")
        command = ["/usr/bin/sbcl", "--dynamic-space-size", "4096", "--noinform",
                   "--non-interactive", "--eval", "(require :asdf)",
                   "--eval", "(asdf:load-system :cl-tpg)",
                   "--load", str(repo / "official-counterfactual-pilot.lisp"),
                   "--load", str(repo / "privileged-search.lisp"),
                   "--eval", "(apply #'cl-tpg::run-privileged-brute-search "
                   f"(cl-tpg::rare-failure-read-form {lisp_string(request_path)}))"]
        try:
            result = subprocess.run(command, cwd=repo, env=env)
        finally:
            report(output)
        return result.returncode


if __name__ == "__main__":
    sys.exit(main())

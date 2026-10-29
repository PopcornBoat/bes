#!/usr/bin/env python3
"""Select target/path gaps and matched-target random controls without action returns."""
import argparse
import hashlib
import importlib.util
import json
import random
from collections import defaultdict
from pathlib import Path


def load_audit_module():
    source = Path(__file__).with_name("analyze-structural-opportunity.py")
    spec = importlib.util.spec_from_file_location("structural_audit", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def manifest(path, groups, source_hash):
    lines = ["(:protocol :response-sweep-v2",
             f' :source-steps-sha256 "{source_hash}"', " :lanes ("]
    for id_, group in enumerate(groups):
        bits = " ".join(str(int(x)) for x in group["bits"])
        lines.append(
            f'  (:id {id_} :terminal "{group["terminal"]}"'
            f' :target {group["target"]} :offset {group["offset"]}'
            f' :bits ({bits}))')
    lines.extend([" ))", ""])
    path.write_text("\n".join(lines))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audit_dir", type=Path)
    parser.add_argument("--seed-root", type=int, required=True)
    parser.add_argument("--random-seed", type=int, default=812731)
    args = parser.parse_args()
    module = load_audit_module()
    module.EXPECTED_SEEDS = [args.seed_root + 197 * i for i in range(100)]
    root = args.audit_dir
    catalogue = module.load_catalogue(root / "catalogue.tsv")
    by_seed = module.load_rows(root / "steps.tsv", catalogue)
    groups, terminal_target = module.build_groups(by_seed)
    candidates = module.build_candidates(groups, terminal_target, catalogue)
    keys = defaultdict(list)
    for row in candidates:
        if row["eligible"] and row["episode_exposure"] >= 40:
            key = (row["terminal"], row["target"], tuple(row["host_bits"]))
            keys[key].append(row)
    options = []
    for (terminal, target, bits), rows in keys.items():
        options.append({
            "terminal": terminal, "target": target, "bits": bits,
            "offset": module.HOST_OFFSETS[target],
            "episode_exposure": rows[0]["episode_exposure"],
            "score": max(row["score"] for row in rows),
            "step_exposure": rows[0]["step_exposure"],
        })
    options.sort(key=lambda row: (-row["score"], row["terminal"],
                                  row["target"], row["bits"]))
    by_target = defaultdict(list)
    for option in options:
        by_target[option["target"]].append(option)
    structural = []
    for row in options:
        if row["target"] not in {x["target"] for x in structural} and len(
                by_target[row["target"]]) >= 2:
            structural.append(row)
        if len(structural) == 5:
            break
    if len(structural) != 5:
        raise ValueError("Fewer than five targets have matched random controls")
    rng = random.Random(args.random_seed)
    controls = []
    for row in structural:
        pool = [x for x in by_target[row["target"]] if x is not row]
        nearest = min(abs(x["episode_exposure"] - row["episode_exposure"])
                      for x in pool)
        matched = [x for x in pool if abs(x["episode_exposure"] -
                                          row["episode_exposure"]) == nearest]
        controls.append(rng.choice(matched))
    digest = hashlib.sha256((root / "steps.tsv").read_bytes()).hexdigest()
    manifest(root / "structural-groups.sexp", structural, digest)
    manifest(root / "random-groups.sexp", controls, digest)
    report = {
        "protocol": "response-sweep-group-selection-v1",
        "seed_root": args.seed_root,
        "eligible_action_rows": sum(row["eligible"] for row in candidates),
        "eligible_groups_with_40_episodes": len(options),
        "random_seed": args.random_seed,
        "structural": structural,
        "random": controls,
        "steps_sha256": digest,
    }
    (root / "group-selection.json").write_text(
        json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()

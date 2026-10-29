#!/usr/bin/env python3
"""Document the prereward B-line fallback when structural scores all vanish."""
import hashlib
import importlib.util
import json
import sys
from pathlib import Path


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: select-bline-coverage-groups.py AUDIT_DIR")
    root = Path(sys.argv[1])
    source = Path(__file__).with_name("analyze-structural-opportunity.py")
    spec = importlib.util.spec_from_file_location("audit", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.EXPECTED_SEEDS = [14000000 + 197*i for i in range(100)]
    catalogue = module.load_catalogue(root / "catalogue.tsv")
    by_seed = module.load_rows(root / "steps.tsv", catalogue)
    groups, terminal_target = module.build_groups(by_seed)
    candidates = module.build_candidates(groups, terminal_target, catalogue)
    unique = {}
    for row in candidates:
        if row["eligible"] and row["episode_exposure"] >= 40:
            key = (row["terminal"], row["target"], tuple(row["host_bits"]))
            unique[key] = {"terminal": key[0], "target": key[1],
                           "bits": key[2], "offset": module.HOST_OFFSETS[key[1]],
                           "episode_exposure": row["episode_exposure"],
                           "score": row["score"]}
    if len(unique) != 5 or any(row["score"] != 0 for row in unique.values()):
        raise ValueError("Frozen B-line coverage fallback no longer applies")
    selected = sorted(unique.values(), key=lambda x: (-x["episode_exposure"],
                                                       x["target"], x["bits"]))
    digest = hashlib.sha256((root / "steps.tsv").read_bytes()).hexdigest()
    lines = ["(:protocol :response-sweep-v2",
             f' :source-steps-sha256 "{digest}"', " :lanes ("]
    for id_, row in enumerate(selected):
        bits = " ".join(str(int(x)) for x in row["bits"])
        lines.append(f'  (:id {id_} :terminal "{row["terminal"]}"'
                     f' :target {row["target"]} :offset {row["offset"]}'
                     f' :bits ({bits}))')
    lines.extend([" ))", ""])
    (root / "coverage-groups.sexp").write_text("\n".join(lines))
    report = {"protocol": "bline-coverage-fallback-v1",
              "reason": "Only five high-exposure eligible groups across four targets; all structural scores zero",
              "steps_sha256": digest, "groups": selected}
    (root / "coverage-groups.json").write_text(json.dumps(report, indent=2)+"\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Freeze paired Level-2 nominations from Level-1 output without reward access."""
import csv
import hashlib
import json
import random
import sys
from pathlib import Path

HOST_OFFSETS = {1: 0, 2: 4, 3: 8, 4: 12, 5: 28,
                7: 36, 8: 40, 9: 44, 10: 48}


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: prepare-matched-lanes.py LEVEL1_DIR OUTPUT_SEXP")
    level1 = Path(sys.argv[1])
    output = Path(sys.argv[2])
    summary = json.loads((level1 / "summary.json").read_text())
    if summary["protocol"] != "structural-opportunity-level1-v1":
        raise ValueError("Unexpected Level-1 protocol")
    source = level1 / "lanes.json"
    lanes = json.loads(source.read_text())
    if len(lanes) != 5:
        raise ValueError("Frozen Level-1 protocol expected five groups")
    with (level1 / "catalogue.tsv").open(newline="") as stream:
        catalogue = {int(row["index"]): (int(row["target"]),
                                         int(row["response"]))
                     for row in csv.DictReader(stream, delimiter="\t")}
    if len(catalogue) != 36:
        raise ValueError("Expected 36 catalogue actions")
    collision_rng = random.Random(271829)
    final = []
    for position, lane in enumerate(lanes):
        target = int(lane["target"])
        structural = int(lane["structural_action"])
        random_action = int(lane["random_action"])
        allowed = [int(index) for index in lane["candidate_action_indices"]]
        if target not in HOST_OFFSETS or len(set(allowed)) != len(allowed):
            raise ValueError("Invalid target or duplicate candidate")
        if any(catalogue[index][0] != target for index in allowed):
            raise ValueError("Lane contains an action on another target")
        if structural not in allowed or random_action not in allowed:
            raise ValueError("Nominated action absent from feasible set")
        collision = structural == random_action
        if collision:
            alternatives = [index for index in allowed
                            if index != structural]
            if not alternatives:
                continue
            random_action = collision_rng.choice(alternatives)
        if random_action == structural:
            raise AssertionError("Collision handling failed")
        bits = tuple(int(value) for value in lane["host_bits"])
        if len(bits) != 4 or tuple(float(value) for value in bits) != tuple(
                lane["host_bits"]):
            raise ValueError("Noncategorical host observation tuple")
        final.append({
            "id": position,
            "terminal": lane["terminal"],
            "target": target,
            "offset": HOST_OFFSETS[target],
            "bits": bits,
            "structural_index": structural,
            "random_index": random_action,
            "collision_resampled": collision,
            "level1_shared_episodes": int(lane["shared_opportunity_episodes"]),
        })
    if not final:
        raise ValueError("All frozen lanes were excluded")
    source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
    lines = [
        "(:protocol :matched-counterfactual-level2-v1",
        f' :level1-lanes-sha256 "{source_hash}"',
        " :lanes",
        " (",
    ]
    for lane in final:
        bits = " ".join(str(value) for value in lane["bits"])
        lines.append(
            f'  (:id {lane["id"]} :terminal "{lane["terminal"]}"'
            f' :target {lane["target"]} :offset {lane["offset"]}'
            f' :bits ({bits})'
            f' :structural-index {lane["structural_index"]}'
            f' :random-index {lane["random_index"]}'
            f' :collision-resampled {"T" if lane["collision_resampled"] else "NIL"})'
        )
    lines.extend([" ))", ""])
    output.write_text("\n".join(lines))
    data = {"level1_lanes_sha256": source_hash, "lanes": final}
    output.with_suffix(".json").write_text(
        json.dumps(data, indent=2) + chr(10))
    print(json.dumps(data, indent=2))


if __name__ == "__main__":
    main()
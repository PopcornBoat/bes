#!/usr/bin/env python3
"""Paired official-return analysis for the frozen matched Level-2 screen."""
import csv
import hashlib
import json
import random
import statistics
import sys
from collections import defaultdict
from pathlib import Path

BOOTSTRAP_REPLICATES = 2000
BOOTSTRAP_SEED = 20261029
MAX_GROUP_EPISODES = 20
SEED_ROOT = 12000000
SEED_COUNT = 100


def numeric(value):
    return float(value.replace("d", "e").replace("D", "e"))


def signs(values):
    return {"positive": sum(value > 1e-8 for value in values),
            "negative": sum(value < -1e-8 for value in values),
            "tie": sum(abs(value) <= 1e-8 for value in values)}


def describe(values):
    if not values:
        return {"n": 0}
    return {"n": len(values), "mean": statistics.mean(values),
            "sd": statistics.stdev(values) if len(values) > 1 else 0.0,
            "min": min(values), "max": max(values), **signs(values)}


def load_events(path, lanes):
    groups = defaultdict(list)
    with path.open(newline="") as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
    expected = {"lane_id", "seed", "step", "terminal", "state_digest",
                "baseline_return", "structural_return", "random_return",
                "structural_delta", "random_delta",
                "structural_minus_random", "baseline_concrete",
                "structural_concrete", "random_concrete",
                "baseline_transitions", "structural_transitions",
                "random_transitions"}
    if not rows or set(rows[0]) != expected:
        raise ValueError("Missing or incompatible Level-2 event table")
    for raw in rows:
        id_ = int(raw["lane_id"])
        if id_ not in lanes:
            raise ValueError(f"Unknown lane {id_}")
        lane = lanes[id_]
        seed = int(raw["seed"])
        if seed not in (SEED_ROOT + 197 * i for i in range(SEED_COUNT)):
            raise ValueError(f"Seed {seed} outside frozen Level-2 block")
        if raw["terminal"] != lane["terminal"] or not raw["state_digest"]:
            raise ValueError("Event path or state digest mismatch")
        event = {
            "lane_id": id_, "seed": seed, "step": int(raw["step"]),
            "baseline": numeric(raw["baseline_return"]),
            "structural": numeric(raw["structural_return"]),
            "random": numeric(raw["random_return"]),
            "s_delta": numeric(raw["structural_delta"]),
            "r_delta": numeric(raw["random_delta"]),
            "s_minus_r": numeric(raw["structural_minus_random"]),
            "baseline_action": int(raw["baseline_concrete"]),
            "structural_action": int(raw["structural_concrete"]),
            "random_action": int(raw["random_concrete"]),
            "baseline_transitions": int(raw["baseline_transitions"]),
            "structural_transitions": int(raw["structural_transitions"]),
            "random_transitions": int(raw["random_transitions"]),
        }
        if not 3 <= event["step"] < 100:
            raise ValueError("Event outside nonopening horizon")
        if len({event["baseline_action"], event["structural_action"],
                event["random_action"]}) != 3:
            raise ValueError("Intervention actions collided")
        if (abs(event["s_delta"] -
                (event["structural"] - event["baseline"])) > 1e-7 or
            abs(event["r_delta"] -
                (event["random"] - event["baseline"])) > 1e-7 or
            abs(event["s_minus_r"] -
                (event["structural"] - event["random"])) > 1e-7):
            raise ValueError("Delta inconsistent with episode returns")
        if (event["structural_transitions"]
                != event["random_transitions"]):
            raise ValueError("Unequal branch transition budget for an event")
        groups[id_].append(event)
    for id_, events in groups.items():
        if len(events) > MAX_GROUP_EPISODES:
            raise ValueError("Group exceeded frozen episode cap")
        if len({event["seed"] for event in events}) != len(events):
            raise ValueError("Repeated seed within a group")
        if [event["seed"] for event in events] != sorted(
                event["seed"] for event in events):
            raise ValueError("Events were not selected in seed order")
    return groups


def primary_bootstrap(groups):
    ids = sorted(groups)
    if any(not groups[id_] for id_ in ids):
        return {"available": False}
    observed = statistics.mean([
        statistics.mean(event["s_minus_r"] for event in groups[id_])
        for id_ in ids])
    by_seed = {
        id_: {event["seed"]: event["s_minus_r"]
              for event in groups[id_]}
        for id_ in ids}
    seed_pool = sorted({seed for values in by_seed.values()
                        for seed in values})
    rng = random.Random(BOOTSTRAP_SEED)
    samples = []
    for _ in range(BOOTSTRAP_REPLICATES):
        sampled = [rng.choice(seed_pool) for _ in seed_pool]
        group_means = []
        for id_ in ids:
            values = [by_seed[id_][seed] for seed in sampled
                      if seed in by_seed[id_]]
            if values:
                group_means.append(statistics.mean(values))
        if len(group_means) == len(ids):
            samples.append(statistics.mean(group_means))
    ordered = sorted(samples)
    if len(ordered) < 0.95 * BOOTSTRAP_REPLICATES:
        raise ValueError("Too many bootstrap samples lacked a group")
    return {
        "available": True, "unweighted_group_mean_s_minus_r": observed,
        "bootstrap_seed": BOOTSTRAP_SEED,
        "bootstrap_replicates": len(ordered),
        "cluster_unit": "seed",
        "bootstrap_95_interval": [
            ordered[int(0.025 * (len(ordered) - 1))],
            ordered[int(0.975 * (len(ordered) - 1))]],
    }


def main():
    if len(sys.argv) != 3:
        raise SystemExit(
            "Usage: analyze-matched-counterfactual.py OUTPUT_DIR MANIFEST_SEXP")
    root = Path(sys.argv[1])
    manifest_path = Path(sys.argv[2])
    manifest_json = manifest_path.with_suffix(".json")
    manifest = json.loads(manifest_json.read_text())
    lanes = {row["id"]: row for row in manifest["lanes"]}
    if len(lanes) != 5 or set(lanes) != set(range(5)):
        raise ValueError("Expected five frozen lanes")
    groups = load_events(root / "events.tsv", lanes)
    group_reports = []
    all_s = []
    all_r = []
    s_transitions = r_transitions = 0
    for id_ in sorted(lanes):
        events = groups[id_]
        s = [event["s_delta"] for event in events]
        r = [event["r_delta"] for event in events]
        pair = [event["s_minus_r"] for event in events]
        all_s.extend(s)
        all_r.extend(r)
        s_transitions += sum(event["structural_transitions"]
                             for event in events)
        r_transitions += sum(event["random_transitions"]
                             for event in events)
        group_reports.append({
            **lanes[id_], "episodes": len(events),
            "structural_delta": describe(s),
            "random_delta": describe(r),
            "structural_minus_random": describe(pair),
            "event_step_mean": statistics.mean(
                event["step"] for event in events) if events else None,
        })
    if s_transitions != r_transitions:
        raise ValueError("Unequal aggregate branch transitions")
    summary = {
        "protocol": "matched-counterfactual-level2-v1",
        "seed_root": SEED_ROOT,
        "seed_count": SEED_COUNT,
        "group_cap": MAX_GROUP_EPISODES,
        "event_count": len(all_s),
        "branch_transitions_each_lane": s_transitions,
        "primary": primary_bootstrap(groups),
        "structural_delta_pooled": describe(all_s),
        "random_delta_pooled": describe(all_r),
        "groups": group_reports,
        "input_sha256": {
            "events.tsv": hashlib.sha256(
                (root / "events.tsv").read_bytes()).hexdigest(),
            "manifest.json": hashlib.sha256(
                manifest_json.read_bytes()).hexdigest(),
        },
    }
    (root / "analysis.json").write_text(
        json.dumps(summary, indent=2) + "\n")
    print(json.dumps({
        key: summary[key] for key in (
            "event_count", "branch_transitions_each_lane", "primary",
            "structural_delta_pooled", "random_delta_pooled", "groups")
    }, indent=2))


if __name__ == "__main__":
    main()
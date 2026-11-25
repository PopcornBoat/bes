#!/usr/bin/env python3
"""Nominate official state/path/target opportunities from separate signals."""
import argparse
import hashlib
import importlib.util
import json
import math
import random
import statistics
from collections import Counter, defaultdict
from pathlib import Path

HOST_OFFSETS = {1: 0, 2: 4, 3: 8, 4: 12, 5: 28,
                7: 36, 8: 40, 9: 44, 10: 48}
LANES = ("missing-support", "suppressed-action", "winner-domination",
         "persistent-behavior", "temporal-mismatch", "overactive-winner",
         "adverse-state-support")


def audit_module():
    source = Path(__file__).with_name("analyze-structural-opportunity.py")
    spec = importlib.util.spec_from_file_location("structural_audit", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def longest_action_run(rows):
    best = current = 0
    previous_step = previous_action = None
    for row in sorted(rows, key=lambda item: item["step"]):
        if (previous_step is not None and row["step"] == previous_step + 1
                and row["selected"] == previous_action):
            current += 1
        else:
            current = 1
        best = max(best, current)
        previous_step, previous_action = row["step"], row["selected"]
    return best


def group_record(key, episodes, catalogue, winner_counts, total_steps,
                 adverse_scores):
    terminal, path, target, bits = key
    rows = [row for episode in episodes.values() for row in episode]
    action_counts = Counter(row["selected"] for row in rows)
    dominant_action, dominant_count = action_counts.most_common(1)[0]
    winners = Counter(row["winner_learner"] for row in rows)
    dominant_winner, winner_count = winners.most_common(1)[0]
    exposure = len(episodes)
    phase_counts = Counter("early" if row["step"] < 50 else "late"
                           for row in rows)
    early_actions = Counter(row["selected"] for row in rows
                            if row["step"] < 50)
    late_actions = Counter(row["selected"] for row in rows
                           if row["step"] >= 50)
    same_phase_winner = bool(early_actions and late_actions and
                             early_actions.most_common(1)[0][0] ==
                             late_actions.most_common(1)[0][0])
    feasible_responses = []
    missing = suppressed = 0
    for index, (candidate_target, response) in catalogue.items():
        if candidate_target != target:
            continue
        feasible = sum(audit_module_bit(row["feasible"], index)
                       for row in rows) / len(rows)
        direct = sum(audit_module_bit(row["direct"], index)
                     for row in rows) / len(rows)
        reachable = sum(audit_module_bit(row["reachable"], index)
                        for row in rows) / len(rows)
        top8 = sum(audit_module_bit(row["top8"], index)
                     for row in rows) / len(rows)
        if feasible >= 0.25:
            feasible_responses.append(response)
            if reachable < 0.05:
                missing += 1
            elif direct >= 0.05 and top8 < 0.05:
                suppressed += 1
    margins = [max(0, min(100, row["bid_margin"]))
               for row in rows if math.isfinite(row["bid_margin"])]
    mean_margin = statistics.mean(margins) if margins else 0.0
    persistent = statistics.mean(longest_action_run(episode)
                                 for episode in episodes.values())
    eligible = exposure >= 10 and len(rows) >= 20 and bool(feasible_responses)
    # Each lane stands alone. No immediate-reward loss factor can zero the
    # other signals; the values nominate experiments, not estimate advantage.
    scores = {
        "missing-support": exposure * missing,
        "suppressed-action": exposure * suppressed,
        "winner-domination": (exposure * winner_counts[dominant_winner]
                              / total_steps * winner_count / len(rows)),
        "persistent-behavior": exposure * persistent / 100,
        "temporal-mismatch": (int(same_phase_winner)
                              * min(phase_counts["early"],
                                  phase_counts["late"]) / len(rows)
                              * exposure * dominant_count / len(rows)),
        "overactive-winner": (exposure * winner_count / len(rows)
                              * mean_margin / (1 + mean_margin)),
        # Restore the frozen Level-1 signal as its own nomination lane. It
        # never multiplies or suppresses the other structural signals.
        "adverse-state-support": adverse_scores.get(
            (terminal, target, bits), 0.0),
    }
    return {
        "terminal": terminal, "path": path, "target": target,
        "offset": HOST_OFFSETS[target], "bits": list(bits),
        "episode_exposure": exposure, "step_exposure": len(rows),
        "dominant_action": dominant_action,
        "dominant_action_rate": dominant_count / len(rows),
        "dominant_winner": dominant_winner,
        "dominant_winner_rate": winner_count / len(rows),
        "feasible_responses": sorted(feasible_responses),
        "missing_response_count": missing,
        "suppressed_response_count": suppressed,
        "longest_action_run_mean": persistent,
        "early_steps": phase_counts["early"],
        "late_steps": phase_counts["late"],
        "mean_bid_margin_capped": mean_margin,
        "scores": scores, "eligible": eligible,
        "example_seed": rows[0]["seed"],
        "example_step": rows[0]["step"],
    }


def audit_module_bit(mask, index):
    return bool(mask & (1 << index))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audit_dir", type=Path)
    parser.add_argument("--seed-root", type=int, required=True)
    parser.add_argument("--random-seed", type=int, default=491731)
    parser.add_argument("--per-lane", type=int, default=1)
    args = parser.parse_args()
    if not 1 <= args.per_lane <= 2:
        raise ValueError("Per-lane budget must be one or two")
    module = audit_module()
    module.EXPECTED_SEEDS = [args.seed_root + 197*i for i in range(100)]
    catalogue = module.load_catalogue(args.audit_dir / "catalogue.tsv")
    by_seed = module.load_rows(args.audit_dir / "steps.tsv", catalogue)
    legacy_groups, terminal_targets = module.build_groups(by_seed)
    legacy_candidates = module.build_candidates(
        legacy_groups, terminal_targets, catalogue)
    adverse_scores = {}
    for row in legacy_candidates:
        if row["eligible"]:
            key = (row["terminal"], row["target"],
                   tuple(row["host_bits"]))
            adverse_scores[key] = max(adverse_scores.get(key, 0.0),
                                      row["score"])
    winner_counts = Counter(row["winner_learner"]
                            for rows in by_seed.values() for row in rows)
    groups = defaultdict(lambda: defaultdict(list))
    for seed, rows in by_seed.items():
        for row in rows:
            for target, offset in HOST_OFFSETS.items():
                bits = tuple(row["observation"][offset:offset+4])
                key = (row["terminal"], row["path"], target, bits)
                groups[key][seed].append(row)
    records = [group_record(key, episodes, catalogue, winner_counts,
                            sum(winner_counts.values()), adverse_scores)
               for key, episodes in groups.items()]
    eligible = [row for row in records if row["eligible"]]
    selected = []
    used = set()
    for lane in LANES:
        ranked = sorted(eligible, key=lambda row: (
            -row["scores"][lane], -row["episode_exposure"],
            row["terminal"], row["path"], row["target"], row["bits"]))
        added = 0
        for row in ranked:
            if row["scores"][lane] <= 0:
                break
            key = (row["terminal"], row["path"], row["target"],
                   tuple(row["bits"]))
            if key not in used:
                used.add(key)
                selected.append({**row, "nomination_lane": lane})
                added += 1
            if added == args.per_lane:
                break
    rng = random.Random(args.random_seed)
    remaining = [row for row in eligible if (
        row["terminal"], row["path"], row["target"], tuple(row["bits"]))
        not in used]
    for proposal in list(selected):
        pool = [row for row in remaining
                if row["target"] == proposal["target"]]
        if not pool:
            continue
        nearest = min(abs(row["episode_exposure"] -
                          proposal["episode_exposure"]) for row in pool)
        matched = [row for row in pool
                   if abs(row["episode_exposure"] -
                          proposal["episode_exposure"]) == nearest]
        control = rng.choice(matched)
        remaining.remove(control)
        selected.append({**control, "nomination_lane": "random-control",
                         "matched_lane": proposal["nomination_lane"]})
    steps_hash = hashlib.sha256((args.audit_dir / "steps.tsv").read_bytes()).hexdigest()
    manifest = ["(:protocol :response-sweep-v2",
                f' :source-steps-sha256 "{steps_hash}"', " :lanes ("]
    for id_, row in enumerate(selected):
        bits = " ".join(str(int(x)) for x in row["bits"])
        manifest.append(
            f'  (:id {id_} :terminal "{row["terminal"]}"'
            f' :path "{row["path"]}" :target {row["target"]}'
            f' :offset {row["offset"]} :bits ({bits})'
            f' :nomination-lane "{row["nomination_lane"]}")')
    manifest.extend([" ))", ""])
    (args.audit_dir / "opportunities.sexp").write_text("\n".join(manifest))
    report = {
        "protocol": "multi-signal-opportunity-v2",
        "seed_root": args.seed_root, "random_seed": args.random_seed,
        "eligible_groups": len(eligible), "total_groups": len(records),
        "steps_sha256": steps_hash,
        "lanes": list(LANES) + ["random-control"],
        "nominations": selected,
    }
    (args.audit_dir / "opportunities.json").write_text(
        json.dumps(report, indent=2) + "\n")
    print(json.dumps({"eligible_groups": len(eligible),
                      "nominations": [{"lane": x["nomination_lane"],
                                       "target": x["target"],
                                       "terminal": x["terminal"],
                                       "bits": x["bits"],
                                       "score": x["scores"].get(
                                           x["nomination_lane"])}
                                      for x in selected]}, indent=2))


if __name__ == "__main__":
    main()

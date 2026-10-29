#!/usr/bin/env python3
"""Frozen Level-1 structural nomination; no counterfactual outcomes are read."""
import argparse
import csv
import hashlib
import json
import random
import statistics
from collections import Counter, defaultdict
from pathlib import Path

PROTOCOL = "structural-opportunity-level1-v1"
EXPECTED_SEEDS = [11000000 + 197 * i for i in range(100)]
HOST_OFFSETS = {1: 0, 2: 4, 3: 8, 4: 12, 5: 28,
                7: 36, 8: 40, 9: 44, 10: 48}
MIN_EPISODES = 10
TOP_K = 5


def numeric(value):
    return float(value.replace("d", "e").replace("D", "e"))


def bit(mask, index):
    return bool(mask & (1 << index))


def mean(values):
    return statistics.mean(values) if values else 0.0


def load_catalogue(path):
    with path.open(newline="") as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
    catalogue = {}
    for row in rows:
        index = int(row["index"])
        catalogue[index] = (int(row["target"]), int(row["response"]))
    if len(catalogue) != 36 or set(catalogue) != set(range(36)):
        raise ValueError("Expected exactly 36 indexed semantic actions")
    if set(target for target, _ in catalogue.values()) != set(HOST_OFFSETS):
        raise ValueError("Catalogue target set differs from frozen host offsets")
    if len(set(catalogue.values())) != 36:
        raise ValueError("Duplicate semantic action in catalogue")
    return catalogue


def load_rows(path, catalogue):
    by_seed = defaultdict(list)
    with path.open(newline="") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        expected = {"seed", "step", "episode_return", "reward", "terminal",
                    "path", "observation", "selected_index", "direct_mask",
                    "reachable_mask", "top8_mask", "feasible_mask",
                    "bid_margin", "state_digest"}
        if set(reader.fieldnames or ()) != expected:
            raise ValueError(f"Unexpected trace columns: {reader.fieldnames}")
        for raw in reader:
            observation = tuple(numeric(value)
                                for value in raw["observation"].split(","))
            if len(observation) != 62:
                raise ValueError("Expected 62 policy observations")
            row = {
                "seed": int(raw["seed"]),
                "step": int(raw["step"]),
                "return": numeric(raw["episode_return"]),
                "reward": numeric(raw["reward"]),
                "terminal": raw["terminal"],
                "path": raw["path"],
                "observation": observation,
                "selected": int(raw["selected_index"]),
                "direct": int(raw["direct_mask"]),
                "reachable": int(raw["reachable_mask"]),
                "top8": int(raw["top8_mask"]),
                "feasible": int(raw["feasible_mask"]),
                "bid_margin": numeric(raw["bid_margin"]),
                "state_digest": raw["state_digest"],
            }
            if row["selected"] != -1:
                if row["selected"] not in catalogue:
                    raise ValueError("Executed pair is outside catalogue")
                if not bit(row["feasible"], row["selected"]):
                    raise ValueError("Executed pair was marked unavailable")
                if not bit(row["top8"], row["selected"]):
                    raise ValueError("Executed pair absent from Top-8")
            by_seed[row["seed"]].append(row)
    if sorted(by_seed) != EXPECTED_SEEDS:
        raise ValueError("Seed block does not match frozen protocol")
    for seed, rows in by_seed.items():
        if [row["step"] for row in rows] != list(range(3, 100)):
            raise ValueError(f"Incomplete or repeated steps for seed {seed}")
        if len({row["return"] for row in rows}) != 1:
            raise ValueError(f"Episode return differs within seed {seed}")
        if any(not row["state_digest"] for row in rows):
            raise ValueError(f"Missing state digest for seed {seed}")
    return by_seed


def longest_run(rows):
    steps = sorted(row["step"] for row in rows)
    best = current = 0
    previous = None
    for step in steps:
        current = current + 1 if previous is not None and step == previous + 1 else 1
        best = max(best, current)
        previous = step
    return best


def build_groups(by_seed):
    groups = defaultdict(lambda: defaultdict(list))
    terminal_target = defaultdict(lambda: defaultdict(list))
    for seed, rows in by_seed.items():
        for row in rows:
            for target, start in HOST_OFFSETS.items():
                values = row["observation"][start:start + 4]
                if len(values) != 4:
                    raise ValueError("Host observation slice outside input")
                key = (row["terminal"], target, values)
                groups[key][seed].append(row)
                terminal_target[(row["terminal"], target)][seed].append(
                    (values, row))
    return groups, terminal_target


def build_candidates(groups, terminal_target, catalogue):
    results = []
    for (terminal, target, values), episodes in groups.items():
        episode_count = len(episodes)
        persistence = mean([longest_run(rows) / 100 for rows in episodes.values()])
        in_group_loss = mean([
            mean([max(0.0, -row["reward"]) for row in rows])
            for rows in episodes.values()
        ])
        complement = {}
        for seed, entries in terminal_target[(terminal, target)].items():
            other = [max(0.0, -row["reward"])
                     for other_values, row in entries if other_values != values]
            if other:
                complement[seed] = mean(other)
        complement_episodes = len(complement)
        out_group_loss = mean(list(complement.values()))
        loss_lift = max(0.0, in_group_loss - out_group_loss)
        all_rows = [row for rows in episodes.values() for row in rows]
        path_counts = Counter(row["path"] for row in all_rows)
        path = path_counts.most_common(1)[0][0]
        for index, (action_target, response) in catalogue.items():
            if action_target != target:
                continue
            direct = mean([bit(row["direct"], index) for row in all_rows])
            reachable = mean([bit(row["reachable"], index) for row in all_rows])
            top8 = mean([bit(row["top8"], index) for row in all_rows])
            executed = mean([row["selected"] == index for row in all_rows])
            feasible = mean([bit(row["feasible"], index) for row in all_rows])
            feasible_episodes = sum(
                any(bit(row["feasible"], index) for row in rows)
                for rows in episodes.values())
            support_deficit = 1.0 - (0.50 * direct + 0.25 * top8
                                     + 0.25 * executed)
            eligible = (episode_count >= MIN_EPISODES
                        and complement_episodes >= MIN_EPISODES
                        and feasible_episodes >= MIN_EPISODES)
            score = ((episode_count / 100) * persistence * loss_lift
                     * support_deficit * feasible) if eligible else None
            if feasible == 0:
                support_type = "controller-unavailable"
            elif direct == 0 and reachable == 0:
                support_type = "missing-active-path-support"
            elif direct == 0:
                support_type = "reachable-via-team-reference"
            elif top8 < 0.05:
                support_type = "direct-learner-suppressed"
            elif executed < 0.05:
                support_type = "ranked-but-not-executed"
            else:
                support_type = "executed"
            results.append({
                "terminal": terminal, "path": path,
                "target": target, "response": response,
                "action_index": index, "host_bits": list(values),
                "episode_exposure": episode_count,
                "complement_episodes": complement_episodes,
                "feasible_episodes": feasible_episodes,
                "step_exposure": len(all_rows),
                "persistence": persistence,
                "group_mean_negative_reward": in_group_loss,
                "complement_mean_negative_reward": out_group_loss,
                "loss_lift": loss_lift,
                "direct_support_rate": direct,
                "reachable_support_rate": reachable,
                "top8_rate": top8,
                "execution_rate": executed,
                "feasibility_rate": feasible,
                "support_deficit": support_deficit,
                "support_type": support_type,
                "eligible": eligible,
                "score": score,
            })
    results.sort(key=lambda x: (
        x["score"] is None,
        -(x["score"] if x["score"] is not None else 0.0),
        x["terminal"], x["target"], x["host_bits"], x["action_index"],
    ))
    eligible_scores = [row["score"] for row in results if row["eligible"]]
    for row in results:
        score = row["score"]
        row["rank_low"] = (1 + sum(other > score for other in eligible_scores)
                           if score is not None else None)
        row["rank_high"] = (sum(other >= score for other in eligible_scores)
                            if score is not None else None)
    return results


def action_ranking(candidates, catalogue):
    scores = {}
    for index in catalogue:
        eligible = [row["score"] for row in candidates
                    if row["action_index"] == index and row["eligible"]]
        scores[index] = max(eligible) if eligible else None
    ranked = []
    for index, score in scores.items():
        other_scores = [value for value in scores.values()
                        if value is not None]
        ranked.append({
            "action_index": index,
            "target": catalogue[index][0],
            "response": catalogue[index][1],
            "best_group_score": score,
            "rank_low": (1 + sum(value > score for value in other_scores)
                         if score is not None else None),
            "rank_high": (sum(value >= score for value in other_scores)
                          if score is not None else None),
            "best_groups": [
                {"terminal": row["terminal"], "host_bits": row["host_bits"],
                 "score": row["score"], "episode_exposure": row["episode_exposure"]}
                for row in candidates
                if row["action_index"] == index and row["score"] == score
            ][:10] if score is not None else [],
        })
    ranked.sort(key=lambda row: (row["best_group_score"] is None,
                                 -(row["best_group_score"] or 0.0),
                                 row["action_index"]))
    return ranked


def lane_proposals(candidates, groups, catalogue):
    """Choose fixed matched opportunities; do not execute either lane."""
    structural_rng = random.Random(314159)
    random_rng = random.Random(271828)
    eligible = [row for row in candidates if row["eligible"]]
    selected_groups = []
    seen = set()
    for row in eligible:
        key = (row["terminal"], row["target"], tuple(row["host_bits"]))
        if key not in seen:
            seen.add(key)
            selected_groups.append(key)
        if len(selected_groups) >= TOP_K:
            break
    lanes = []
    for key in selected_groups:
        rows = groups[key]
        entries = [row for row in eligible
                   if (row["terminal"], row["target"], tuple(row["host_bits"])) == key]
        if not entries:
            continue
        best_score = max(row["score"] for row in entries)
        best = [row for row in entries if row["score"] == best_score]
        structural = structural_rng.choice(best)
        random_candidates = [row for row in entries
                             if row["feasible_episodes"] >= MIN_EPISODES]
        random_pick = random_rng.choice(random_candidates)
        matched_episodes = sum(
            any(bit(state["feasible"], structural["action_index"])
                and bit(state["feasible"], random_pick["action_index"])
                and state["selected"] != structural["action_index"]
                and state["selected"] != random_pick["action_index"]
                for state in states)
            for states in rows.values())
        lanes.append({
            "terminal": key[0], "target": key[1], "host_bits": list(key[2]),
            "structural_action": structural["action_index"],
            "structural_tie_width": len(best),
            "random_action": random_pick["action_index"],
            "same_action": (structural["action_index"]
                            == random_pick["action_index"]),
            "shared_opportunity_episodes": matched_episodes,
            "candidate_action_indices": [
                row["action_index"] for row in random_candidates],
        })
    return lanes


def write_csv(path, rows):
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    root = args.directory
    catalogue = load_catalogue(root / "catalogue.tsv")
    by_seed = load_rows(root / "steps.tsv", catalogue)
    groups, terminal_target = build_groups(by_seed)
    candidates = build_candidates(groups, terminal_target, catalogue)
    actions = action_ranking(candidates, catalogue)
    lanes = lane_proposals(candidates, groups, catalogue)
    write_csv(root / "candidates.csv", candidates)
    write_csv(root / "action-ranking.csv", actions)
    user2_restore = next(row for row in actions
                         if (row["target"], row["response"]) == (8, 2))
    result = {
        "protocol": PROTOCOL,
        "seed_count": len(by_seed),
        "step_count": sum(map(len, by_seed.values())),
        "group_count": len(groups),
        "candidate_count": len(candidates),
        "eligible_count": sum(row["eligible"] for row in candidates),
        "top_k": TOP_K,
        "known_positive_control": {
            "action": [8, 2],
            "catalogue_index": user2_restore["action_index"],
            "rank_low": user2_restore["rank_low"],
            "rank_high": user2_restore["rank_high"],
            "unambiguous_top5": (
                user2_restore["rank_high"] is not None
                and user2_restore["rank_high"] <= TOP_K),
        },
        "top_actions": actions[:10],
        "matched_lanes": lanes,
        "input_sha256": {
            name: hashlib.sha256((root / name).read_bytes()).hexdigest()
            for name in ("steps.tsv", "catalogue.tsv")
        },
    }
    (root / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    (root / "lanes.json").write_text(json.dumps(lanes, indent=2) + "\n")
    print(json.dumps({key: result[key] for key in (
        "seed_count", "step_count", "group_count", "candidate_count",
        "eligible_count", "known_positive_control", "top_actions",
        "matched_lanes")}, indent=2))


if __name__ == "__main__":
    main()
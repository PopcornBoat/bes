#!/usr/bin/env python3
"""Read-only analysis of frozen official incumbent rollout audits.

All return comparisons are observational nominations, never action advantages.
One episode contributes at most one value to each state/action estimate.
"""
import argparse
import csv
import hashlib
import json
import math
import statistics
from collections import Counter, defaultdict
from pathlib import Path

HOST_OFFSETS = {1: 0, 2: 4, 3: 8, 4: 12, 5: 28,
                7: 36, 8: 40, 9: 44, 10: 48}
PHASES = ((0, 30, "early"), (30, 50, "middle"), (50, 101, "late"))
SCHEMA = "official-experience-analysis-v1"


def number(value):
    return float(value.replace("d", "e").replace("D", "e"))


def phase(step):
    return next(name for lower, upper, name in PHASES
                if lower <= step < upper)


def mean(values):
    return statistics.mean(values) if values else 0.0


def bit(mask, index):
    return bool(mask & (1 << index))


def catalogue_from(path):
    with path.open(newline="") as stream:
        entries = {int(row["index"]): (int(row["target"]),
                                       int(row["response"]))
                   for row in csv.DictReader(stream, delimiter="\t")}
    if set(entries) != set(range(36)) or len(set(entries.values())) != 36:
        raise ValueError(f"Invalid Semantic-36 catalogue: {path}")
    return entries


def policy_hash(root):
    lines = (root / "input-sha256.txt").read_text().splitlines()
    if not lines or len(lines[0].split()) < 2:
        raise ValueError(f"Missing checkpoint identity: {root}")
    digest = lines[0].split()[0]
    if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise ValueError(f"Invalid checkpoint SHA-256: {root}")
    return digest


def load_audit(root, environment):
    """Load one worker's files, rejecting incomplete or inconsistent episodes."""
    environment_file = root / "environment.txt"
    if (environment_file.exists() and
            environment_file.read_text().strip() != environment):
        raise ValueError(f"Environment identity differs: {root}")
    catalogue = catalogue_from(root / "catalogue.tsv")
    policy = policy_hash(root)
    by_seed = defaultdict(list)
    with (root / "steps.tsv").open(newline="") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        required = {"seed", "step", "episode_return", "reward", "terminal",
                    "path", "observation", "selected_index", "direct_mask",
                    "reachable_mask", "top8_mask", "feasible_mask",
                    "winner_learner"}
        if not required <= set(reader.fieldnames or ()):
            raise ValueError(f"Incomplete structural trace: {root}")
        for raw in reader:
            obs = tuple(number(x) for x in raw["observation"].split(","))
            if len(obs) != 62:
                raise ValueError("Expected exactly 62 policy inputs")
            selected = int(raw["selected_index"])
            feasible = int(raw["feasible_mask"])
            top8 = int(raw["top8_mask"])
            if selected != -1 and (selected not in catalogue or
                                   not bit(feasible, selected) or
                                   not bit(top8, selected)):
                raise ValueError("Selected Semantic-36 action lacks feasible Top-8 support")
            by_seed[int(raw["seed"])].append({
                "step": int(raw["step"]), "reward": number(raw["reward"]),
                "total": number(raw["episode_return"]),
                "obs": obs, "selected": selected,
                "terminal": raw["terminal"], "path": raw["path"],
                "winner": raw["winner_learner"],
                "direct": int(raw["direct_mask"]),
                "reachable": int(raw["reachable_mask"]),
                "top8": top8, "feasible": feasible,
            })
    executions = defaultdict(dict)
    sidecar = root / "executions-v2.tsv"
    if not sidecar.exists():
        sidecar = root / "executions-v1.tsv"
    if not sidecar.exists():
        sidecar = root / "executions.tsv"  # Provisional audit.
    if sidecar.exists():
        with sidecar.open(newline="") as stream:
            reader = csv.DictReader(stream, delimiter="\t")
            required = {"seed", "step", "reward", "episode_return",
                        "selected_index", "incumbent_concrete",
                        "actual_concrete", "decoy_mask_before",
                        "controller_step_before", "scan_before",
                        "ranked_indices", "terminated", "truncated"}
            if not required <= set(reader.fieldnames or ()):
                raise ValueError(f"Incomplete execution trace: {sidecar}")
            has_proposal = "proposed_index" in (reader.fieldnames or ())
            for raw in reader:
                seed, step = int(raw["seed"]), int(raw["step"])
                if step in executions[seed]:
                    raise ValueError(f"Repeated execution step {seed}/{step}")
                if int(raw["actual_concrete"]) != int(raw["incumbent_concrete"]):
                    raise ValueError("Non-incumbent action in purported incumbent audit")
                if not 0 <= int(raw["actual_concrete"]) <= 144:
                    raise ValueError("Concrete CAGE2 action outside 0..144")
                if int(raw["controller_step_before"]) != step:
                    raise ValueError("Controller step drift")
                scan = tuple(number(x) for x in raw["scan_before"].split(","))
                if len(scan) != 10:
                    raise ValueError("Incomplete Controller scan state")
                ranked = tuple(int(x) for x in raw["ranked_indices"].split(",")
                               if x)
                proposal = int(raw["proposed_index"]) if has_proposal else None
                if (proposal is not None and proposal !=
                    (ranked[0] if ranked else -1)):
                    raise ValueError("Semantic proposal differs from recorded ranking")
                executions[seed][step] = {
                    "reward": number(raw["reward"]),
                    "total": number(raw["episode_return"]),
                    "selected": int(raw["selected_index"]),
                    "concrete": int(raw["actual_concrete"]),
                    "decoy_mask": int(raw["decoy_mask_before"]),
                    "scan": scan,
                    "ranked": ranked, "proposal": proposal,
                    "done": bool(int(raw["terminated"]) or int(raw["truncated"])),
                }
    if not by_seed or (sidecar.exists() and set(by_seed) != set(executions)):
        raise ValueError("Missing or unmatched official episodes")
    episodes = {}
    for seed, rows in by_seed.items():
        rows.sort(key=lambda row: row["step"])
        if [row["step"] for row in rows] != list(range(3, 3 + len(rows))):
            raise ValueError(f"Missing or repeated policy step for seed {seed}")
        if len({row["total"] for row in rows}) != 1:
            raise ValueError("Episode total differs between steps")
        if sidecar.exists():
            acts = executions[seed]
            if sorted(acts) != list(range(len(acts))):
                raise ValueError(f"Missing execution step for seed {seed}")
            if (any(acts[step]["done"] for step in range(len(acts) - 1)) or
                not acts[len(acts) - 1]["done"]):
                raise ValueError("Official termination/truncation boundary mismatch")
            if rows[-1]["step"] != max(acts):
                raise ValueError("Policy trace ends before official episode")
            if not math.isclose(sum(x["reward"] for x in acts.values()),
                                rows[0]["total"], abs_tol=1e-7):
                raise ValueError("Step rewards do not sum to official episode return")
            for row in rows:
                action = acts[row["step"]]
                if (row["selected"] != action["selected"] or
                    not math.isclose(row["reward"], action["reward"],
                                     abs_tol=1e-9) or
                    row["obs"][52:] != action["scan"]):
                    raise ValueError("Semantic action, reward, or Controller scan mismatch")
                row["concrete"] = action["concrete"]
                row["decoy_mask"] = action["decoy_mask"]
                row["ranked"] = action["ranked"]
                row["proposal"] = action["proposal"]
                row["previous_concrete"] = (
                    acts[row["step"] - 1]["concrete"] if row["step"] else None)
            full_rewards = [acts[i]["reward"] for i in range(len(acts))]
        else:
            full_rewards = [0.0] * 3 + [row["reward"] for row in rows]
        suffix = 0.0
        for step in range(len(full_rewards) - 1, 2, -1):
            suffix += full_rewards[step]
            rows[step - 3]["rtg"] = suffix
        episodes[(environment, policy, seed)] = rows
    return episodes, catalogue, sidecar.exists()


def episode_values(rows, field):
    """Aggregate correlated repeated steps before computing a group mean."""
    by_episode = defaultdict(list)
    for key, row in rows:
        by_episode[key].append(row[field])
    return [mean(values) for values in by_episode.values()]


def analyze(roots, environment, min_episodes=5):
    episodes = {}
    catalogue = None
    global_masks = {}
    verified = unverified = 0
    execution_counts = Counter()
    proposal_counts = Counter()
    concrete_counts = Counter()
    controller_reroutes = 0
    for root in roots:
        loaded, local_catalogue, has_executions = load_audit(root, environment)
        if catalogue is not None and catalogue != local_catalogue:
            raise ValueError("Semantic catalogues differ between workers")
        catalogue = local_catalogue
        if set(loaded) & set(episodes):
            raise ValueError("Duplicate policy/environment/seed across workers")
        mask_file = root / "global-support.txt"
        if mask_file.exists():
            mask = int(mask_file.read_text().strip())
            policy = next(iter(loaded))[1]
            if policy in global_masks and global_masks[policy] != mask:
                raise ValueError("Conflicting global genotype support for policy")
            global_masks[policy] = mask
        episodes.update(loaded)
        verified += len(loaded) if has_executions else 0
        unverified += len(loaded) if not has_executions else 0
        for rows in loaded.values():
            for row in rows:
                execution_counts[row["selected"]] += 1
                if "concrete" in row:
                    concrete_counts[row["concrete"]] += 1
                    if row["proposal"] is not None:
                        proposal_counts[row["proposal"]] += 1
                        controller_reroutes += row["proposal"] != row["selected"]
    # Raw RTG has a deterministic horizon trend. Remove the within-policy
    # same-step mean before comparing actions taken at different times.
    step_returns = defaultdict(list)
    for key, rows in episodes.items():
        for row in rows:
            step_returns[(key[1], row["step"])].append(row["rtg"])
    step_means = {key: mean(values) for key, values in step_returns.items()}
    for key, rows in episodes.items():
        for row in rows:
            row["adjusted_rtg"] = (
                row["rtg"] - step_means[(key[1], row["step"])])
    groups = defaultdict(list)
    exact_groups = defaultdict(list)
    for key, rows in episodes.items():
        for row in rows:
            exact_groups[(key[1], row["terminal"], phase(row["step"]),
                          row["obs"])].append((key, row))
            for target, offset in HOST_OFFSETS.items():
                state = tuple(row["obs"][offset:offset + 4])
                group = (key[1], row["terminal"], phase(row["step"]),
                         target, state)
                groups[group].append((key, row))
    opportunities = []
    history_diagnostics = []
    comparable = 0
    for group, records in groups.items():
        policy, terminal, period, target, state = group
        exposed = len({key for key, _ in records})
        if exposed < min_episodes:
            continue
        by_action = defaultdict(list)
        for key, row in records:
            by_action[row["selected"]].append((key, row))
        action_stats = {
            action: {"episodes": len({key for key, _ in items}),
                     "mean_rtg": mean(episode_values(items, "rtg")),
                     "mean_adjusted_rtg": mean(
                         episode_values(items, "adjusted_rtg")),
                     "sd_adjusted_rtg": (
                         statistics.stdev(
                             episode_values(items, "adjusted_rtg"))
                         if len(episode_values(items, "adjusted_rtg")) > 1
                         else None)}
            for action, items in by_action.items()
        }
        observed = [(a, s) for a, s in action_stats.items()
                    if s["episodes"] >= min_episodes]
        dominant = max(by_action, key=lambda a: len(by_action[a]))
        group_id = hashlib.sha256(repr(group).encode()).hexdigest()[:16]
        base = {"group_id": group_id, "policy_sha256": policy,
                "terminal_team": terminal, "phase": period,
                "target": target, "host_bits": state,
                "episode_exposure": exposed,
                "active_path": Counter(row["path"] for _, row in records)
                               .most_common(1)[0][0],
                "winning_learner": Counter(row["winner"] for _, row in records)
                                   .most_common(1)[0][0],
                "dominant_action": dominant,
                "action_counts": {str(a): s["episodes"]
                                  for a, s in sorted(action_stats.items())}}
        histories = defaultdict(list)
        for key, row in records:
            if "previous_concrete" in row:
                histories[row["previous_concrete"]].append((key, row))
        comparable_histories = [
            (action, episode_values(items, "adjusted_rtg"))
            for action, items in histories.items()
            if len({key for key, _ in items}) >= min_episodes]
        if len(comparable_histories) >= 2:
            history_diagnostics.append({
                **base,
                "history_feature": "previous_executed_concrete_action",
                "history_values": [
                    {"concrete_action": action, "episodes": len(values),
                     "mean_step_adjusted_rtg": mean(values)}
                    for action, values in sorted(comparable_histories)],
                "observed_step_adjusted_rtg_spread": (
                    max(mean(values) for _, values in comparable_histories) -
                    min(mean(values) for _, values in comparable_histories)),
                "interpretation": "Association only; full observation and hidden state may differ",
            })
        if len(observed) >= 2:
            comparable += 1
            winner, best = max(
                observed, key=lambda item: item[1]["mean_adjusted_rtg"])
            adjusted_delta = (best["mean_adjusted_rtg"] -
                              action_stats[dominant]["mean_adjusted_rtg"])
            if winner != dominant and adjusted_delta > 0:
                opportunities.append({
                    **base, "source_lanes": ["observational-return"],
                    "lane_scores": {
                        "observational-return": adjusted_delta},
                    "proposed_action": winner,
                    "observed_delta_rtg": best["mean_rtg"] -
                                          action_stats[dominant]["mean_rtg"],
                    "observed_delta_step_adjusted_rtg": adjusted_delta,
                    "candidate_adjusted_rtg_sd": best["sd_adjusted_rtg"],
                    "dominant_adjusted_rtg_sd": (
                        action_stats[dominant]["sd_adjusted_rtg"]),
                    "comparison_episodes": best["episodes"],
                    "alternative_feasible_episodes": len({
                        key for key, row in records
                        if bit(row["feasible"], winner)}),
                    "alternative_top8_episodes": len({
                        key for key, row in records
                        if bit(row["top8"], winner)}),
                    "reason": "Same-step-adjusted action RTG association; confounded",
                })
        eligible = []
        for action, (action_target, _) in catalogue.items():
            if action_target != target or action == dominant:
                continue
            feasible_eps = len({key for key, row in records
                                if bit(row["feasible"], action)})
            if feasible_eps < min_episodes:
                continue
            top8_eps = len({key for key, row in records
                            if bit(row["top8"], action)})
            direct_eps = len({key for key, row in records
                              if bit(row["direct"], action)})
            reachable_eps = len({key for key, row in records
                                 if bit(row["reachable"], action)})
            selected_eps = action_stats.get(action, {}).get("episodes", 0)
            eligible.append((action, feasible_eps, top8_eps, direct_eps,
                             reachable_eps, selected_eps))
        for action, feasible, top8, direct, reachable, selected in eligible:
            global_mask = global_masks.get(policy)
            support = ("missing-global-support"
                       if global_mask is not None and
                       not bit(global_mask, action) else
                       "missing-active-support" if reachable == 0 else
                       "suppressed-or-unrouted" if top8 == 0 else
                       "ranked-but-not-executed")
            opportunities.append({
                **base, "source_lanes": ["coverage"],
                "lane_scores": {
                    "coverage": feasible * (1 - selected / exposed)
                                * (1 - top8 / exposed)},
                "proposed_action": action, "support_type": support,
                "global_supported": (
                    None if global_mask is None else bit(global_mask, action)),
                "feasible_episodes": feasible,
                "direct_episodes": direct,
                "reachable_episodes": reachable,
                "top8_episodes": top8, "selected_episodes": selected,
                "reason": "Executable action has limited active support",
            })
        # Repeated decisions under negative reward nominate an intervention
        # location. The alternative remains unverified.
        longest = 0
        evidence = set()
        example = None
        for key in {key for key, _ in records}:
            sequence = sorted((row for owner, row in records if owner == key),
                              key=lambda row: row["step"])
            run = 0
            run_start = None
            previous = None
            for row in sequence:
                if (previous and row["step"] == previous["step"] + 1 and
                    row["selected"] == previous["selected"] and
                    row["reward"] < 0):
                    run += 1
                else:
                    run = 1 if row["reward"] < 0 else 0
                    run_start = row["step"] if run else None
                if run >= 4:
                    evidence.add(key)
                    if example is None or run > example["length"]:
                        example = {"seed": key[2], "start": run_start,
                                   "end": row["step"], "length": run,
                                   "repeated_action": row["selected"]}
                longest = max(longest, run)
                previous = row
        if len(evidence) >= min_episodes and eligible:
            episode_key = next(key for key in evidence
                               if key[2] == example["seed"])
            next_row = next((row for row in episodes[episode_key]
                             if row["step"] == example["end"] + 1), None)
            least_supported = min(
                eligible, key=lambda item: (item[5], item[2], -item[1],
                                            item[0]))
            opportunities.append({
                **base, "source_lanes": ["persistent-failure"],
                "lane_scores": {
                    "persistent-failure": len(evidence) * longest / 100},
                "proposed_action": least_supported[0],
                "longest_negative_repeat": longest,
                "independent_failure_episodes": len(evidence),
                "example_seed": example["seed"],
                "example_step_range": [example["start"], example["end"]],
                "example_repeated_action": example["repeated_action"],
                "example_next_action": (
                    next_row["selected"] if next_row else None),
                "reason": "Repeated negative-reward action; coverage-based alternative is hypothetical",
            })
    # Preserve provenance when two lanes identify the same opportunity.
    combined = {}
    for row in opportunities:
        key = (row["group_id"], row["proposed_action"])
        if key in combined:
            combined[key]["source_lanes"].extend(row["source_lanes"])
            combined[key]["lane_scores"].update(row["lane_scores"])
            combined[key].update({k: v for k, v in row.items()
                                  if k not in ("source_lanes", "lane_scores",
                                               "reason")})
            combined[key]["reason"] += "; " + row["reason"]
        else:
            combined[key] = row
    ordered = sorted(combined.values(),
                     key=lambda r: (-len(r["source_lanes"]),
                                    -r["episode_exposure"],
                                    r["group_id"], r["proposed_action"]))
    lane_rankings = {
        lane: [
            {"group_id": row["group_id"],
             "proposed_action": row["proposed_action"],
             "score": row["lane_scores"][lane]}
            for row in sorted(
                (item for item in ordered if lane in item["source_lanes"]),
                key=lambda item: (-item["lane_scores"][lane],
                                  -item["episode_exposure"],
                                  item["group_id"], item["proposed_action"]))[:10]]
        for lane in ("observational-return", "persistent-failure", "coverage")
    }
    return {
        "schema": SCHEMA, "environment": environment,
        "audit_directories": [str(x) for x in roots],
        "episodes": len(episodes), "verified_full_return_episodes": verified,
        "legacy_partial_episodes": unverified,
        "eligible_state_groups": sum(
            len({key for key, _ in rows}) >= min_episodes
            for rows in groups.values()),
        "groups_with_observed_action_overlap": comparable,
        "exact_observation_groups_with_overlap": sum(
            sum(len({key for key, row in rows
                     if row["selected"] == action}) >= min_episodes
                for action in {row["selected"] for _, row in rows}) >= 2
            for rows in exact_groups.values()),
        "global_genotype_support": {
            policy: [action for action in range(36) if bit(mask, action)]
            for policy, mask in sorted(global_masks.items())},
        "execution_coverage": {
            "semantic_resolved_counts": dict(sorted(execution_counts.items())),
            "semantic_proposal_counts": dict(sorted(proposal_counts.items())),
            "concrete_action_counts": dict(sorted(concrete_counts.items())),
            "controller_proposal_changes": controller_reroutes,
            "note": "Counts cover policy steps 3+; opening actions are excluded from structural rows."},
        "lane_rankings": lane_rankings,
        "history_diagnostics": sorted(
            history_diagnostics,
            key=lambda row: (-row["episode_exposure"],
                             -row["observed_step_adjusted_rtg_spread"],
                             row["group_id"]))[:30],
        "history_note": "Previous action is an analysis feature only; observation and hidden state remain possible confounders.",
        "opportunities": ordered,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audits", nargs="+", type=Path)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--min-episodes", type=int, default=5)
    args = parser.parse_args()
    if args.min_episodes < 2:
        parser.error("--min-episodes must be at least 2")
    report = analyze(args.audits, args.environment, args.min_episodes)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: report[k] for k in (
        "episodes", "verified_full_return_episodes",
        "eligible_state_groups", "groups_with_observed_action_overlap")}))


if __name__ == "__main__":
    main()

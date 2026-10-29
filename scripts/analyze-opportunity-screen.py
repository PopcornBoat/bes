#!/usr/bin/env python3
"""Summarize multi-lane official response screens without changing nominations."""
import argparse
import csv
import json
import statistics
from collections import defaultdict
from pathlib import Path


def real(value):
    return float(value.replace("d", "e").replace("D", "e"))


def stats(values):
    if not values:
        return {"n": 0}
    return {"n": len(values), "mean": statistics.mean(values),
            "sd": statistics.stdev(values) if len(values) > 1 else 0.0,
            "positive": sum(x > 1e-8 for x in values),
            "negative": sum(x < -1e-8 for x in values),
            "tie": sum(abs(x) <= 1e-8 for x in values),
            "min": min(values), "max": max(values)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("screen_dir", type=Path)
    parser.add_argument("nominations", type=Path)
    parser.add_argument("--seed-root", type=int, required=True)
    args = parser.parse_args()
    source = json.loads(args.nominations.read_text())
    nominations = source["nominations"]
    with (args.screen_dir / "events.tsv").open(newline="") as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
    by_event = defaultdict(list)
    by_group = defaultdict(list)
    for row in rows:
        group = int(row["group"])
        seed = int(row["seed"])
        response = int(row["response"])
        if not 0 <= group < len(nominations) or response not in range(4):
            raise ValueError("Unexpected group/response")
        if seed not in {args.seed_root+197*i for i in range(100)}:
            raise ValueError("Seed outside frozen screen block")
        if row["cohort"] not in ("discovery", "confirmation"):
            raise ValueError("Invalid cohort")
        if row["status"] not in ("INTERVENED", "SAME", "UNAVAILABLE"):
            raise ValueError("Invalid status")
        if abs(real(row["delta"]) -
               (real(row["branch_return"])-real(row["baseline_return"]))) > 1e-7:
            raise ValueError("Return delta mismatch")
        if row["status"] == "INTERVENED" and int(row["branch_transitions"]) <= 0:
            raise ValueError("Intervention lacks official transitions")
        observation = tuple(real(x) for x in row["observation"].split(","))
        if len(observation) != 62:
            raise ValueError("Incorrect observation size")
        record = {"group": group, "seed": seed, "cohort": row["cohort"],
                  "step": int(row["step"]), "response": response,
                  "status": row["status"], "delta": real(row["delta"]),
                  "observation": observation,
                  "state_digest": row["state_digest"],
                  "branch_transitions": int(row["branch_transitions"])}
        by_event[(group, seed)].append(record)
        by_group[group].append(record)
    reports = []
    for group, nomination in enumerate(nominations):
        events = sorted((seed, records) for (id_, seed), records in by_event.items()
                        if id_ == group)
        if len(events) > 40:
            raise ValueError("Group exceeded screen cap")
        for seed, records in events:
            if len(records) != 4 or {r["response"] for r in records} != set(range(4)):
                raise ValueError("Each state must screen four responses")
            if len({r["state_digest"] for r in records}) != 1 or len(
                    {r["observation"] for r in records}) != 1:
                raise ValueError("Responses did not share one official state")
        cohorts = {}
        for cohort in ("discovery", "confirmation"):
            data = {}
            for response in range(4):
                cases = [r for r in by_group[group]
                         if r["cohort"] == cohort and r["response"] == response]
                available = [r for r in cases if r["status"] != "UNAVAILABLE"]
                data[str(response)] = {
                    "opportunities": len(cases),
                    "available": len(available),
                    "interventions": sum(r["status"] == "INTERVENED" for r in cases),
                    "branch_transitions": sum(r["branch_transitions"] for r in cases),
                    "delta": stats([r["delta"] for r in available]),
                }
            cohorts[cohort] = data
        choices = [(cohorts["discovery"][str(r)]["delta"]["mean"], r)
                   for r in range(4)
                   if cohorts["discovery"][str(r)]["available"] >= 15]
        chosen = min(choices, key=lambda x: (-x[0], x[1]))[1] if choices else None
        complete = len(events) == 40
        confirm = cohorts["confirmation"].get(str(chosen)) if chosen is not None else None
        passed = bool(complete and confirm and confirm["available"] >= 15
                      and confirm["delta"].get("mean", 0) > 0
                      and confirm["delta"].get("positive", 0) >= 15)
        reports.append({"group": group, "nomination": nomination,
                        "matched_episodes": len(events),
                        "complete": complete, "chosen_response": chosen,
                        "confirmation_pass": passed,
                        "cohorts": cohorts})
    report = {
        "protocol": "multi-signal-opportunity-screen-v1",
        "seed_root": args.seed_root,
        "baseline_episodes": 100,
        "groups": reports,
        "branch_transitions": sum(int(row["branch_transitions"])
                                  for row in rows),
        # This is observational reporting only; no nomination or acceptance
        # condition reads this known positive-control category.
        "meander_user2_restore_soft_metric": {
            "nominated_target_groups": sum(
                x["nomination"]["target"] == 8 for x in reports),
            "response_screen_passes": sum(
                x["nomination"]["target"] == 8 and
                x["chosen_response"] == 2 and x["confirmation_pass"]
                for x in reports),
        },
    }
    (args.screen_dir / "opportunity-analysis.json").write_text(
        json.dumps(report, indent=2) + "\n")
    print(json.dumps({
        "branch_transitions": report["branch_transitions"],
        "groups": [{"id": x["group"], "lane": x["nomination"]["nomination_lane"],
                    "target": x["nomination"]["target"],
                    "response": x["chosen_response"],
                    "passed": x["confirmation_pass"]} for x in reports],
        "soft_metric": report["meander_user2_restore_soft_metric"]}, indent=2))


if __name__ == "__main__":
    main()

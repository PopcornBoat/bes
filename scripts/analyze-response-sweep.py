#!/usr/bin/env python3
"""Analyze the frozen four-response official counterfactual sweep."""
import csv
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path


def number(value):
    return float(value.replace("d", "e").replace("D", "e"))


def describe(values):
    if not values:
        return {"n": 0}
    return {
        "n": len(values), "mean": statistics.mean(values),
        "median": statistics.median(values),
        "sd": statistics.stdev(values) if len(values) > 1 else 0,
        "positive": sum(x > 1e-8 for x in values),
        "negative": sum(x < -1e-8 for x in values),
        "tie": sum(abs(x) <= 1e-8 for x in values),
        "min": min(values), "max": max(values),
    }


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: analyze-response-sweep.py OUTPUT_DIRECTORY")
    root = Path(sys.argv[1])
    with (root / "events.tsv").open(newline="") as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
    if not rows:
        raise ValueError("No response-sweep events")
    groups = defaultdict(lambda: defaultdict(list))
    event_rows = defaultdict(list)
    for row in rows:
        group = int(row["group"])
        seed = int(row["seed"])
        response = int(row["response"])
        if group not in range(5) or response not in range(4):
            raise ValueError("Unexpected group or response")
        if seed not in {13000000 + 197 * i for i in range(100)}:
            raise ValueError("Seed outside frozen block")
        if row["cohort"] not in ("discovery", "confirmation"):
            raise ValueError("Unknown cohort")
        if row["status"] not in ("UNAVAILABLE", "SAME", "INTERVENED"):
            raise ValueError("Unknown response status")
        base = number(row["baseline_return"])
        branch = number(row["branch_return"])
        delta = number(row["delta"])
        if abs(delta - (branch - base)) > 1e-7:
            raise ValueError("Return delta mismatch")
        if (row["status"] == "INTERVENED") != (int(row["branch_transitions"]) > 0):
            raise ValueError("Branch budget/status mismatch")
        if row["status"] == "INTERVENED" and row["baseline_concrete"] == row["branch_concrete"]:
            raise ValueError("No concrete change")
        if row["status"] != "INTERVENED" and abs(delta) > 1e-7:
            raise ValueError("Non-intervention changed reward")
        record = {"seed": seed, "step": int(row["step"]),
                  "status": row["status"], "delta": delta,
                  "branch_transitions": int(row["branch_transitions"])}
        groups[(group, row["cohort"])][response].append(record)
        event_rows[(group, seed)].append(row)
    if len(event_rows) != 200:
        raise ValueError("Expected 40 matched episodes for each of five groups")
    for (group, seed), event in event_rows.items():
        if len(event) != 4 or {int(x["response"]) for x in event} != set(range(4)):
            raise ValueError("Each state must have exactly four responses")
        for key in ("cohort", "step", "state_digest", "baseline_return", "baseline_concrete"):
            if len({x[key] for x in event}) != 1:
                raise ValueError(f"Responses did not share one state: {key}")
    output = []
    for group in range(5):
        cohorts = {}
        for cohort in ("discovery", "confirmation"):
            responses = groups[(group, cohort)]
            seed_lists = [set(x["seed"] for x in responses[r]) for r in range(4)]
            if len(seed_lists[0]) != 20 or any(s != seed_lists[0] for s in seed_lists):
                raise ValueError("Cohort response opportunities mismatch")
            result = {}
            for response in range(4):
                records = responses[response]
                available = [x for x in records if x["status"] != "UNAVAILABLE"]
                result[str(response)] = {
                    "available": len(available),
                    "interventions": sum(x["status"] == "INTERVENED" for x in records),
                    "official_branch_transitions": sum(x["branch_transitions"] for x in records),
                    "delta_available": describe([x["delta"] for x in available]),
                }
            cohorts[cohort] = result
        choices = [(cohorts["discovery"][str(r)]["delta_available"]["mean"], r)
                   for r in range(4)
                   if cohorts["discovery"][str(r)]["available"] >= 15]
        selected = min(choices, key=lambda x: (-x[0], x[1]))[1] if choices else None
        output.append({"group": group, "selected_response": selected,
                       "discovery": cohorts["discovery"],
                       "confirmation": cohorts["confirmation"],
                       "selected_confirmation": (
                           cohorts["confirmation"][str(selected)] if selected is not None
                           else None)})
    report = {
        "protocol": "response-sweep-v1", "seeds_scanned": 100,
        "groups": output,
        "total_official_branch_transitions": sum(int(x["branch_transitions"]) for x in rows),
    }
    (root / "analysis.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"group_selections": [
        {"group": x["group"], "response": x["selected_response"],
         "confirmation": x["selected_confirmation"]} for x in output],
        "branch_transitions": report["total_official_branch_transitions"]}, indent=2))


if __name__ == "__main__":
    main()

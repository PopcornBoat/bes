#!/usr/bin/env python3
"""Analysis-only action execution metric from official policy rollouts."""
import argparse
import csv
import json
import statistics
from pathlib import Path


def number(text):
    return float(text.replace("d", "e").replace("D", "e"))


def summarize(path, action_index):
    episodes = {}
    with path.open(newline="") as stream:
        for row in csv.DictReader(stream, delimiter="\t"):
            seed = int(row["seed"])
            episode = episodes.setdefault(seed, {"actions": 0, "steps": 0,
                                                  "return": None})
            episode["steps"] += 1
            episode["actions"] += int(int(row["selected_index"]) == action_index)
            episode["return"] = number(row["episode_return"])
    if not episodes:
        raise ValueError(f"No policy episodes in {path}")
    return {"episodes": len(episodes),
            "decision_steps": sum(x["steps"] for x in episodes.values()),
            "action_executions": sum(x["actions"] for x in episodes.values()),
            "episodes_with_action": sum(x["actions"] > 0
                                        for x in episodes.values()),
            "mean_episode_return": statistics.mean(x["return"]
                                                    for x in episodes.values())}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("catalogue", type=Path)
    parser.add_argument("incumbent_audit", type=Path)
    parser.add_argument("candidate_audit", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--target", type=int, required=True)
    parser.add_argument("--response", type=int, required=True)
    args = parser.parse_args()
    with args.catalogue.open(newline="") as stream:
        matching = [int(row["index"]) for row in csv.DictReader(
            stream, delimiter="\t") if int(row["target"]) == args.target
            and int(row["response"]) == args.response]
    if len(matching) != 1:
        raise ValueError("Expected one action in the catalogue")
    incumbent = summarize(args.incumbent_audit, matching[0])
    candidate = summarize(args.candidate_audit, matching[0])
    report = {"target": args.target, "response": args.response,
              "catalogue_index": matching[0], "incumbent": incumbent,
              "candidate": candidate,
              "execution_change": candidate["action_executions"] -
                                  incumbent["action_executions"],
              "mean_return_change": candidate["mean_episode_return"] -
                                    incumbent["mean_episode_return"]}
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()

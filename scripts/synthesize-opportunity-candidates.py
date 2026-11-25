#!/usr/bin/env python3
"""Compile reward-supported state/action hypotheses into bounded gate variants."""
import argparse
import csv
import json
import random
import statistics
from collections import defaultdict
from pathlib import Path

ROR_VALUES = (0.0, 1.0, 2.0, 3.0)


def number(value):
    return float(value.replace("d", "e").replace("D", "e"))


def lisp_float(value):
    rendered = format(value, ".17g")
    if "e" in rendered:
        return rendered.replace("e", "d")
    if "." not in rendered:
        rendered += ".0"
    return rendered + "d0"


def lisp_vector(observation):
    return "#(" + " ".join(lisp_float(x) for x in observation) + ")"


def predicate_score(predicate, positive, negative, background):
    index, value = predicate
    coverage = sum(x[index] == value for x in positive) / len(positive)
    in_group_false = (sum(x[index] == value for x in negative)
                      / max(1, len(negative)))
    collateral = (sum(x[index] == value for x in background)
                  / max(1, len(background)))
    return coverage - 0.7*in_group_false - 0.7*collateral, coverage, collateral


def choose_predicates(positive, negative, background):
    singles = []
    for index in range(62):
        for ror, value in enumerate(ROR_VALUES):
            predicate = ((index, value),)
            score, coverage, collateral = predicate_score(
                (index, value), positive, negative, background)
            if coverage >= 0.6:
                singles.append((score, coverage, collateral, (index, ror),
                                predicate))
    singles.sort(key=lambda x: (-x[0], -x[1], x[2], x[3]))
    best_single = singles[0] if singles and singles[0][0] > 0 else None
    # Search a bounded set of conjunctions using only discovery states.
    pool = [x[3] for x in singles[:20]]
    pairs = []
    for i, first in enumerate(pool):
        for second in pool[i+1:]:
            if first[0] == second[0]:
                continue
            def hit(obs):
                return all(obs[index] == ROR_VALUES[ror]
                           for index, ror in (first, second))
            coverage = sum(map(hit, positive))/len(positive)
            if coverage < 0.6:
                continue
            in_group_false = sum(map(hit, negative))/max(1, len(negative))
            collateral = sum(map(hit, background))/max(1, len(background))
            score = coverage - 0.7*in_group_false - 0.7*collateral
            pairs.append((score, coverage, collateral, (first, second)))
    pairs.sort(key=lambda x: (-x[0], -x[1], x[2], x[3]))
    best_pair = pairs[0] if pairs and pairs[0][0] > 0 else None
    return best_single, best_pair


def read_screen(path):
    result = defaultdict(lambda: defaultdict(list))
    with path.open(newline="") as stream:
        for row in csv.DictReader(stream, delimiter="\t"):
            group = int(row["group"])
            response = int(row["response"])
            result[group][response].append({
                "seed": int(row["seed"]), "cohort": row["cohort"],
                "status": row["status"], "delta": number(row["delta"]),
                "observation": tuple(number(x) for x in
                                     row["observation"].split(",")),
            })
    return result


def background_observations(path, rng):
    by_seed = defaultdict(list)
    with path.open(newline="") as stream:
        for row in csv.DictReader(stream, delimiter="\t"):
            by_seed[int(row["seed"])].append(
                tuple(number(x) for x in row["observation"].split(",")))
    sample = []
    for seed in sorted(by_seed):
        rows = by_seed[seed]
        sample.extend(rng.sample(rows, min(2, len(rows))))
    return sample


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("screen_dir", type=Path)
    parser.add_argument("audit_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    analysis = json.loads((args.screen_dir / "opportunity-analysis.json").read_text())
    screen = read_screen(args.screen_dir / "events.tsv")
    rng = random.Random(7301)
    background = background_observations(args.audit_dir / "steps.tsv", rng)
    possibilities = []
    for row in analysis["groups"]:
        response = row["chosen_response"]
        if response is None:
            continue
        group = row["group"]
        cases = [case for case in screen[group][response]
                 if case["cohort"] == "discovery"
                 and case["status"] != "UNAVAILABLE"]
        positive = [case["observation"] for case in cases
                    if case["delta"] > 1e-8]
        negative = [case["observation"] for case in cases
                    if case["delta"] <= 1e-8]
        if len(positive) < 2:
            continue
        mean = statistics.mean(case["delta"] for case in cases)
        if not row["confirmation_pass"] and mean <= 0:
            continue
        possibilities.append({"group": group, "response": response,
                              "nomination": row["nomination"],
                              "confirmed": row["confirmation_pass"],
                              "mean_discovery": mean,
                              "positive": positive, "negative": negative})
    possibilities.sort(key=lambda x: (not x["confirmed"],
                                     -x["mean_discovery"], x["group"]))
    selected = possibilities[:4]
    candidates = []
    for hypothesis in selected:
        single, pair = choose_predicates(hypothesis["positive"],
                                         hypothesis["negative"], background)
        variants = []
        if single:
            variants.extend([
                ("single-terminal", (single[3],), 1000.0, "TERMINAL"),
                ("single-root", (single[3],), 250.0, "ROOT")])
        if pair:
            variants.append(("double-terminal", pair[3], 1000.0, "TERMINAL"))
        for name, predicates, margin, insertion in variants:
            candidates.append({
                "id": f'g{hypothesis["group"]}-{name}',
                "group": hypothesis["group"],
                "lane": hypothesis["nomination"]["nomination_lane"],
                "target": hypothesis["nomination"]["target"],
                "response": hypothesis["response"],
                "terminal": hypothesis["nomination"]["terminal"],
                "predicates": predicates, "margin": margin,
                "insertion": insertion,
                "probe": hypothesis["positive"][0],
                "background": background[:20],
                "confirmed_one_step": hypothesis["confirmed"],
                "mean_discovery": hypothesis["mean_discovery"],
            })
    lines = ["(:protocol :active-specialist-incubation-v1", " :candidates ("]
    for candidate in candidates:
        predicates = " ".join(f'({i} {r})' for i, r in candidate["predicates"])
        backgrounds = " ".join(lisp_vector(x) for x in candidate["background"])
        lines.append(
            f'  (:id "{candidate["id"]}" :group {candidate["group"]}'
            f' :lane "{candidate["lane"]}"'
            f' :target {candidate["target"]} :response {candidate["response"]}'
            f' :terminal "{candidate["terminal"]}"'
            f' :predicates ({predicates}) :margin {lisp_float(candidate["margin"])}'
            f' :insertion :{candidate["insertion"]}'
            f' :probe {lisp_vector(candidate["probe"])}'
            f' :background ({backgrounds}))')
    lines.extend([" ))", ""])
    (args.output_dir / "candidate-manifest.sexp").write_text("\n".join(lines))
    report = {"protocol": "active-specialist-incubation-v1",
              "hypotheses": [{key: value for key, value in hypothesis.items()
                              if key not in ("positive", "negative")}
                             for hypothesis in selected],
              "candidate_count": len(candidates),
              "candidates": [{key: value for key, value in candidate.items()
                              if key not in ("probe", "background")}
                             for candidate in candidates],
              "meander_user2_restore_soft_metric": {
                  "hypotheses": sum(x["nomination"]["target"] == 8 and
                                    x["response"] == 2 for x in selected),
                  "variants": sum(x["target"] == 8 and x["response"] == 2
                                  for x in candidates),
              }}
    (args.output_dir / "candidate-plan.json").write_text(
        json.dumps(report, indent=2)+"\n")
    print(json.dumps({"candidate_count": len(candidates),
                      "soft_metric": report["meander_user2_restore_soft_metric"]},
                     indent=2))


if __name__ == "__main__":
    main()

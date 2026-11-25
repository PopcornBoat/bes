"""Deterministic checks for extreme-optimize search and result accounting."""
import csv
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "bes_extreme"))
from evaluate import rank_nominations, validate_table, HOSTS
from search import Policy, budget_for, combined_moves, holdout_check, rounds, single_moves


class SearchTest(unittest.TestCase):
    def setUp(self):
        self.a, self.b = "Enterprise0", "Defender"
        self.parent = Policy({self.a: [0, 1], self.b: [2, 3], "User0": []}, {}, {})

    def test_interleaved_permutations_keep_option_sets_and_parent(self):
        self.assertEqual(single_moves(self.parent, ["User0", self.a, self.b], 2),
                         [(self.a, [1, 0]), (self.b, [3, 2])])
        self.assertEqual(single_moves(self.parent, [self.a, self.b], 1), [(self.a, [1, 0])])
        self.assertEqual(self.parent.table[self.a], [0, 1])

    def test_joint_budgets_exclude_nonimproving_orders(self):
        rows = [(self.b, [3, 2], -54), (self.a, [1, 0], -55),
                (self.b, [2, 3], -56), (self.a, [0, 1], -56)]
        self.assertEqual(combined_moves(rows, -56, 8, 4), [{self.a: [1, 0], self.b: [3, 2]}])
        self.assertEqual(combined_moves(rows, -56, 0, 4), [])

    def test_round_scores_joint_schedule_and_stops_without_improvement(self):
        def evaluate(policy, root):
            a = policy.table[self.a] == [1, 0]
            b = policy.table[self.b] == [3, 2]
            return {"total": -56 + a + 2 * b + int(a and b), "evidence": "fixture"}

        jobs = SimpleNamespace(evaluate=evaluate,
                               batch=lambda policies, root: [evaluate(p, root) for p in policies])
        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(root=153, rounds=3, hosts=[self.a, self.b], single_budget=2,
                                   joint_budget=1, joint_width=1, graph_budget=0, output=Path(directory))
            best, baseline, score, history = rounds(args, self.parent, jobs)
        self.assertEqual((baseline["total"], score["total"]), (-56, -52))
        self.assertEqual(best.table, {self.a: [1, 0], self.b: [3, 2], "User0": []})
        self.assertEqual(len(history), 2)
        self.assertEqual(history[0]["tested"][-1]["family"], "combined-hosts")

    def test_reject_holdout_degradation_and_any_new_catastrophe(self):
        def result(total, bline=0, meander=0):
            return {"total": total, "cells": {
                f"100-{red}": {"mean": total, "below_minus100": count, "cvar10": -30}
                for red, count in (("B_lineAgent", bline), ("RedMeanderAgent", meander))
            }}

        original = result(-56)
        self.assertTrue(holdout_check([(42, original, result(-55))], 0)["accepted"])
        self.assertFalse(holdout_check([(42, original, result(-57))], 0)["accepted"])
        self.assertTrue(holdout_check([(42, original, result(-57))], 1)["accepted"])
        self.assertFalse(holdout_check([(42, original, result(-50, meander=1))], 0)["accepted"])

    def test_official_budget_counts_trace_and_both_holdout_policies(self):
        args = SimpleNamespace(evaluate_only=False, rounds=1, single_budget=24, joint_budget=8,
                               graph_budget=2, holdout=[42, 290150561], episodes=1000)
        self.assertEqual(budget_for(args), 21_600_000)
        args.evaluate_only = True
        self.assertEqual(budget_for(args), 540_000)

    def test_table_validation_rejects_duplicate_or_nonintegral_choices(self):
        table = {host: [] for host in HOSTS}
        validate_table(table)
        for invalid in ([1, 1], [True], [-1], [8]):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                validate_table({**table, self.a: invalid})


class NominationTest(unittest.TestCase):
    def test_loss_weighting_and_alignment(self):
        with tempfile.TemporaryDirectory() as directory:
            actions, contexts = (Path(directory) / name for name in ("actions.tsv", "contexts.tsv"))
            with actions.open("w", newline="", encoding="utf-8") as stream:
                writer = csv.writer(stream, delimiter="\t")
                writer.writerows([["route", "concrete", "reward"], ["bline", 1, -3],
                                  ["bline", 1, 1], ["meander", 3, -1], ["sleep", 4, -99]])
            a, b = "0" * 62, "1" * 62
            records = [f"bline\t1\t{a}\t2:0", f"bline\t1\t{a}\t2:0",
                       f"meander\t3\t{b}\t3:1", "sleep\t4\t-\t-"]
            contexts.write_text("\n".join(records) + "\n", encoding="utf-8")
            output = rank_nominations(actions, contexts)
            self.assertEqual([(o["route"], o["loss"], o["observations"]) for o in output],
                             [("bline", 3, 2), ("meander", 1, 1)])
            contexts.write_text("\n".join(records[:3]) + "\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                rank_nominations(actions, contexts)
            contexts.write_text("\n".join(records).replace("bline\t1", "bline\t2") + "\n",
                                encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "out of sync"):
                rank_nominations(actions, contexts)


if __name__ == "__main__":
    unittest.main()

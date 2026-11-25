"""Accounting checks for read-only official experience analysis."""
import csv
import importlib.util
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "analyze-official-experience.py"
SPEC = importlib.util.spec_from_file_location("official_experience", MODULE_PATH)
experience = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(experience)


def fixture(root, choices=(0, 0, 1, 1), policy="a" * 64, sidecar=True):
    root.mkdir(parents=True, exist_ok=True)
    (root / "input-sha256.txt").write_text(policy + "  frozen-policy.lisp\n")
    (root / "environment.txt").write_text("Cage2-test-v0\n")
    with (root / "catalogue.tsv").open("w", newline="") as file:
        writer = csv.writer(file, delimiter="\t")
        writer.writerow(("index", "target", "response"))
        for target_index, target in enumerate(experience.HOST_OFFSETS):
            for response in range(4):
                writer.writerow((target_index * 4 + response, target, response))
    with (root / "steps.tsv").open("w", newline="") as file:
        writer = csv.writer(file, delimiter="\t")
        writer.writerow(("seed", "step", "episode_return", "reward",
                         "terminal", "path", "observation", "selected_index",
                         "direct_mask", "reachable_mask", "top8_mask",
                         "feasible_mask", "winner_learner"))
        for seed, action in enumerate(choices, 100):
            rewards = (-2.0, -3.0) if action == 0 else (-1.0, -1.0)
            for step, reward in enumerate(rewards, 3):
                writer.writerow((seed, step, f"{sum(rewards)}d0",
                                 f"{reward}d0", "TEAM-1",
                                 "ROOT>TEAM-1", ",".join(["0.0d0"] * 62),
                                 action, (1 << 36) - 1, (1 << 36) - 1,
                                 3, (1 << 36) - 1, "LEARNER-1"))
    if sidecar:
        with (root / "executions-v2.tsv").open("w", newline="") as file:
            writer = csv.writer(file, delimiter="\t")
            writer.writerow(("seed", "step", "reward", "episode_return",
                             "proposed_index", "selected_index", "incumbent_concrete",
                             "actual_concrete", "decoy_mask_before",
                             "controller_step_before", "scan_before",
                             "ranked_indices", "terminated", "truncated"))
            for seed, action in enumerate(choices, 100):
                rewards = (0.0, 0.0, 0.0, -2.0, -3.0) if action == 0 else (
                    0.0, 0.0, 0.0, -1.0, -1.0)
                for step, reward in enumerate(rewards):
                    writer.writerow((seed, step, f"{reward}d0",
                                     f"{sum(rewards)}d0",
                                     action if step >= 3 else -1,
                                     action if step >= 3 else -1,
                                     2 + action, 2 + action, 0, step,
                                     ",".join(["0.0d0"] * 10),
                                     f"{action},{1 - action}" if step >= 3 else "",
                                     0, int(step == 4)))


class OfficialExperienceTests(unittest.TestCase):
    def test_full_reward_and_action_accounting(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "worker"
            fixture(root)
            episodes, _, verified = experience.load_audit(root, "Cage2-test-v0")
            self.assertTrue(verified)
            rows = episodes[("Cage2-test-v0", "a" * 64, 100)]
            self.assertEqual([row["rtg"] for row in rows], [-5.0, -3.0])
            self.assertEqual(rows[0]["concrete"], 2)
            self.assertEqual(rows[0]["previous_concrete"], 2)
            self.assertEqual(rows[0]["proposal"], 0)
            report = experience.analyze([root], "Cage2-test-v0", 2)
            self.assertEqual(report["verified_full_return_episodes"], 4)
            self.assertGreater(report["groups_with_observed_action_overlap"], 0)
            self.assertTrue(any("observational-return" in row["source_lanes"]
                                for row in report["opportunities"]))
            self.assertTrue(all(row["active_path"] == "ROOT>TEAM-1"
                                for row in report["opportunities"]))
            self.assertEqual(report["execution_coverage"]["controller_proposal_changes"], 0)

    def test_no_observed_alternative_is_reported_as_missing_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "worker"
            fixture(root, choices=(0, 0))
            report = experience.analyze([root], "Cage2-test-v0", 2)
            self.assertEqual(report["groups_with_observed_action_overlap"], 0)
            self.assertFalse(any("observational-return" in row["source_lanes"]
                                 for row in report["opportunities"]))

    def test_rejects_reward_and_controller_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "worker"
            fixture(root)
            sidecar = root / "executions-v2.tsv"
            text = sidecar.read_text().replace("-3.0d0", "-4.0d0", 1)
            sidecar.write_text(text)
            with self.assertRaisesRegex(ValueError, "sum to official"):
                experience.load_audit(root, "Cage2-test-v0")

    def test_rejects_duplicate_worker_episodes(self):
        with tempfile.TemporaryDirectory() as directory:
            first, second = Path(directory) / "a", Path(directory) / "b"
            fixture(first)
            fixture(second)
            with self.assertRaisesRegex(ValueError, "Duplicate policy"):
                experience.analyze([first, second], "Cage2-test-v0", 2)
            fixture(second, policy="b" * 64)
            self.assertEqual(experience.analyze(
                [first, second], "Cage2-test-v0", 2)["episodes"], 8)

    def test_legacy_trace_is_explicitly_partial(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "worker"
            fixture(root, choices=(0, 0), sidecar=False)
            report = experience.analyze([root], "Cage2-test-v0", 2)
            self.assertEqual(report["legacy_partial_episodes"], 2)
            self.assertEqual(report["verified_full_return_episodes"], 0)

    def test_rejects_environment_or_proposal_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "worker"
            fixture(root)
            with self.assertRaisesRegex(ValueError, "Environment identity"):
                experience.load_audit(root, "Other-v0")
            sidecar = root / "executions-v2.tsv"
            text = sidecar.read_text().replace("0,1", "1,0", 1)
            sidecar.write_text(text)
            with self.assertRaisesRegex(ValueError, "proposal differs"):
                experience.load_audit(root, "Cage2-test-v0")


if __name__ == "__main__":
    unittest.main()

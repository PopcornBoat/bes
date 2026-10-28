# First visible User2 compromise: one-step official Restore test

Date: 2026-10-28. Experimental branch: `official-counterfactual-replay`. No training was run, and the protected checkpoint was not changed.

## Frozen hypothesis

The Meander gen-463 TPG checkpoint has no User2 Restore terminal in the active `TEAM-0-33` route for its persistent User2-compromise states. An independent 200-seed policy audit found User2 host penalty -6.95 per episode for TPG versus -0.38 for the exported PPO policy. This motivated a teacher-free official counterfactual:

1. Run the frozen TPG from reset in `Cage2-meander-100-v0`.
2. Choose the **first** step at or after step 3 where User2's two compromise observation bits (zero-based indices 42 and 43) are `[0,1]`, meaning `User` in the official BlueTableWrapper's observation encoding, and the incumbent concrete action is not User2 Restore.
3. Replay the same seed and exact concrete-action prefix. At that step, force semantic `(8,2)`, which must resolve to concrete action 142, then resume the frozen TPG for the rest of the 100-step episode.
4. Compare complete episode returns on the paired seed. The replay checks simulator/Python RNG/bridge-state digest, policy observation, ranking, concrete action and reward throughout the prefix.

The trigger rule and seed blocks were frozen before the main runs. The smoke test used separate seeds. Discovery used `9200000 + 197*i`, `i=0..49`; independent holdout used `9400000 + 197*i`, `i=0..149`. Neither block overlaps the earlier 6M/7M/8M/9.1M cohorts.

## Results

| Cohort | Eligible / requested | Positive / negative / zero | Mean return change among eligible | SE |
|---|---:|---:|---:|---:|
| Discovery | 47 / 50 | 36 / 11 / 0 | +2.402 | 0.552 |
| Independent holdout | 135 / 150 | 92 / 42 / 1 | +1.557 | 0.277 |

The approximate normal 95% interval for the holdout eligible mean is [+1.013,+2.101]. Including the 15 ineligible seeds as zero effect, the held-out rule mean is +1.401 over all 150 seeds (SE 0.252; approximate interval [+0.906,+1.896]). Holdout individual deltas ranged from -9.3 to +10.0. A positive mean does not make every episode safer.

The holdout event occurred at mean step 31.5 (median 29). Descriptive subgroup means: steps 3-19, +1.44 (38 events); steps 20-39, +2.11 (68); steps 40-59, +0.37 (19); steps 60-99, +0.51 (10). The late groups are small, and these phase comparisons were not the frozen primary hypothesis.

All 182 eligible baseline/branch tape pairs were independently replayed through official CAGE2. Every recorded concrete action and step reward matched. Holdout average reward-component changes, branch minus baseline, were:

| Component | Mean change |
|---|---:|
| User2 host penalty | +1.820 |
| Action cost | -0.274 |
| All other host penalties combined | +0.011 |
| Complete return | +1.557 |

User2 host penalty improved in 135/135 eligible holdout branches. The one-time Restore immediately cleared the visible User2 `User` marker in 135/135. That marker later reappeared in 125/135, with a median 12-step delay among recurrences. Under the one-time-intervention branch, there were on average 49.4 later steps with the marker. This records recurrence under the frozen TPG after one intervention; it does **not** measure what a repeated-Restore policy would do.

## Interpretation and next gate

This is strong evidence for a **beneficial first User2 Restore intervention** on the frozen gen-463 TPG under the stated 100-step Meander protocol. It identifies a more consequential official-return direction than the earlier User3 Decoy bid repair. The value arises mostly from reduced User2 host penalty, despite the Restore action's cost.

It is not yet evidence that a stateless 62-input TPG genotype can trigger just once or route correctly without collateral changes. The existing active terminal team lacks User2 Restore, so a candidate needs a learner/route change, not a bid tweak of a learner already in that team. The 42 negative holdout episodes and visible recurrence require explicit repeated-trigger, action-cost and tail checks. The concrete-action tape is exact up to intervention; later different actions may consume RNG differently, so paired seeds do not imply identical later stochastic events.

The next implementation experiment is to generate a narrow User2 Restore specialist or route variant, measure its behavior on a protected probe archive, then compare its **closed-loop** policy to this unchanged parent on new paired official seeds. The current counterfactual policy does not become a checkpoint or a Controller override.

## Artifacts

Raw results and reproducibility data:
`/home/hardison/bes-artifacts/validations/meander-user2-first-restore-20261028/`

- `discovery/summary.sexp`, `holdout/summary.sexp`: all seeds, eligibility, deltas and observations.
- `*/episodes/seed-*.sexp`: complete baseline and intervention trajectories for every eligible seed.
- `reward-components.csv`: independently replayed per-seed host penalties and action costs.
- `event-strata.json`, `post-restore-visibility.csv`: event timing and later marker recurrence.
- `input-sha256.txt`, `protocol.txt`, `run.log`: input identity, frozen rule and execution record.

Reproduction:
```bash
bash /home/hardison/bes-artifacts/worktrees/official-counterfactual-replay/scripts/run-user2-first-restore-test PARENT.lisp OUTPUT_DIR SEED_ROOT COUNT COHORT
```

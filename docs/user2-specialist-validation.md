# User2 Restore specialist: official Meander evaluation

Date: 2026-10-28. Branch: `official-counterfactual-replay`. This is a standalone genotype experiment. The protected parent checkpoint was not changed.

## Construction

Parent: `/home/hardison/bes-artifacts/validations/meander-bid-guidance-gen463-20261026/checkpoints/bid-guidance-gen463.lisp` (SHA256 `de2b3f3b09b24cd6c011afe1f8247dacfd4fc55a0381a621529a40af521a0312`).

A complete serialize/deserialize copy of the parent graph receives one direct terminal learner in the active `TEAM-0-33` route. Its semantic-36 action is `(User2, Restore) = (8,2)`; the Controller resolves it to concrete CAGE2 action 142. Its seven-instruction program checks `obs[42] == ROR0 (0)` and `obs[43] == ROR1 (1)` and bids low outside that conjunction. On the gate, its bid is `4.4845747811889645`, just above the parent's local winning bid `4.484564781188965` on discovery events. The learner is appended, preserving the incumbent's tie priority. All original learners, edges, and programs remain in the candidate graph.

The bid-quantile generator considered 25%, 50%, 75%, 95%, and 100% of the parent local winning bids. All quantiles coincided, yielding one unique candidate. No arbitrary duplicate variants were evaluated. The candidate uses 62 inputs, stateless execution, fixed Meander heuristic Decoy order, and the existing fixed opening.

## Discovery behavior screen

The earlier one-step counterfactual discovery cohort contained 47 eligible first User2-compromise events; 40 routed through `TEAM-0-33`. The candidate chose User2 Restore on all 40. Across 372 distinct parent-trajectory observations, Top-1 changed in 41 states, all with the User2 marker; 0 of 259 states without that marker changed Top-1. This screen used discovery states only and did not use the previous 150-seed holdout.

## Paired complete-episode results

Every comparison reset the official Python CAGE2 environment to the same initial seed for parent and candidate, then ran each policy to the episode limit. They shared no policy or Controller state. Different later actions may consume random numbers differently.

| Horizon | Seed block | Episodes | Parent mean | Candidate mean | Paired change | SE | Better / worse / equal |
|---|---|---:|---:|---:|---:|---:|---:|
| 100-step scout | `9600000 + 197*i` | 30 | -20.770 | -16.093 | +4.677 | 0.707 | 25 / 5 / 0 |
| 30-step confirmation | `9850000 + 197*i` | 200 | -5.555 | -5.615 | -0.060 | 0.052 | 47 / 64 / 89 |
| 50-step confirmation | `9850000 + 197*i` | 200 | -10.222 | -9.111 | +1.111 | 0.126 | 117 / 42 / 41 |
| 100-step confirmation | `9800000 + 197*i` | 200 | -22.608 | -17.8735 | +4.7345 | 0.2736 | 167 / 18 / 15 |

The 100-step approximate normal 95% interval for paired improvement is [+4.198,+5.271]; the 50-step interval is [+0.863,+1.359]. The 30-step interval is [-0.162,+0.042], so that small measured loss is uncertain. Summing the three confirmation means gives parent -38.385, candidate -32.5995, and a descriptive difference of +5.7855 under this **200-episode-per-horizon** protocol. This is not the standard 1000-episode-per-horizon full validation.

On the 100-step confirmation block, the candidate executed User2 Restore 3.21 times per episode on average, versus zero for the parent. The visible User2 compromise marker appeared for 4.405 steps on average, versus 63.025 for the parent. Marker duration improved in 185 episodes and was equal in 15; none worsened. The worst episode return change was -3.5. On the 50-step block, candidate Restore count averaged 1.435 and marker duration fell from 19.985 to 2.11 steps. On the 30-step block, Restore count averaged 0.665 and marker duration fell from 5.875 to 1.34 steps.

The independent confirmation seed blocks are disjoint from the prior first-intervention discovery and holdout blocks and from the 30-seed scout. The 30-step and 50-step comparisons intentionally use the same seed block across horizons.

## Standard rollout and checkpoint safety

The candidate's serialized graph was byte-for-byte identical before and after adding the parent-derived `:TEACHER-BACKEND :HEURISTIC` metadata. A fresh `load-best-team` followed by the ordinary `cl-gym:rollout` exactly reproduced both recorded returns on confirmation seed 9800000: parent -30.2, candidate -23.5. This checks the standard policy execution path and Controller profile against the experiment runner.

The parent checkpoint hash remained unchanged. The candidate is saved separately as `/home/hardison/bes-artifacts/validations/meander-user2-specialist-20261028/candidate-1.lisp` with `:FITNESS NIL`; it has **not** replaced any historical best or entered a training population. The next step is to test incorporation of this kind of targeted specialist variation into evolution, with ordinary official admission/promotion and fresh seeds. The present result establishes that this particular hand-constructed genotype change improves the frozen parent under these tests; it does not establish that evolution will create or retain it automatically.

## Reproduction and data

The source is `user2-specialist-candidate.lisp`; the launchers are `scripts/run-user2-specialist-screen` and `scripts/run-user2-specialist-official`. They use the current WSL bridge virtual environment. Full records, seed lists, logs, the unscored candidate, and the standard-rollout check are under `/home/hardison/bes-artifacts/validations/meander-user2-specialist-20261028/`.

    bash scripts/run-user2-specialist-screen PARENT.lisp DISCOVERY_DIR OUTPUT_DIR
    bash scripts/run-user2-specialist-official PARENT.lisp CANDIDATE.lisp OUTPUT.sexp SEED_ROOT COUNT COHORT HORIZON
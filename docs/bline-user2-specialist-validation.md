# B-line User2 Restore specialist: controlled transfer test

Date: 2026-10-28. Branch: `official-counterfactual-replay`.

## Question and protected baseline

The Meander checkpoint improved after a new User2 Restore learner was installed. This experiment asks whether the **same targeted repair** improves the independently validated B-line v14 policy. The baseline is `validated-checkpoints/bline-v14/bline-62-36-v14.lisp`, SHA256 `0d023ad8ad0f8191751e2a205b09c8bc5d3a15c2f17e1ca604ca0a3830fd0aa4`. It uses 62 observations, Semantic-36 terminals, stateless execution, and fixed heuristic Decoy order. Its prior standard full score was -28.4841. The baseline file remained unchanged.

## Frozen first-intervention test

The first eligible step at or after step 3 had User2 observation bits 42 and 43 equal to [0,1], and the original policy did not execute concrete User2 Restore 142. Replaying the same seed and exact concrete-action prefix, the test forced one (User2, Restore) = (8,2) and then resumed the frozen B-line v14 policy.

| Cohort | Seeds | Eligible | Eligible mean paired change | SE | Positive / negative |
|---|---:|---:|---:|---:|---:|
| Discovery | 50 | 13 | -1.108 | 1.018 | 6 / 7 |
| Independent holdout | 150 | 36 | +0.369 | 0.546 | 22 / 14 |

The holdout approximate normal 95% interval is [-0.701,+1.440]. Across all 150 seeds, treating the 114 ineligible episodes as unchanged, the mean rule effect was +0.089. This offers no reliable evidence for a beneficial first User2 Restore on B-line v14. The eligible events tended to occur early.

## Independent specialist checkpoint

A complete serialize/deserialize copy of v14 received one appended terminal learner in the active `TEAM-0-310` route. Its gate uses the same two User2 categorical bits as the Meander candidate. The parent's winning bid on all 13 routed discovery events was 0, so all bid quantiles collapsed to one candidate with on-gate bid 0.00001. Its terminal action is (8,2). It selected User2 Restore on all 13 discovery events. On 22 distinct discovery observations, Top-1 changed in six, all with the User2 marker; none without the marker changed.

The experimental candidate was saved locally as `/home/hardison/bes-artifacts/validations/bline-user2-first-restore-20261028/specialists/candidate-1.lisp`. It has no historical fitness and did not replace v14.

## Official paired closed-loop episodes

Each row compares the original v14 and the candidate on the same initial official CAGE2 seeds for complete episodes. No teacher or Controller override supplied candidate actions. The 30-step and 50-step rows used the same new seed block; the 100-step row used another independent block. A separate 30-seed 100-step scout first showed mean change -1.087 (SE 0.897).

| Horizon | Seed block | Episodes | v14 mean | Candidate mean | Paired change | SE | Approximate 95% interval | Better / worse / equal |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| 30 | `10300000 + 197*i` | 200 | -4.4930 | -4.6990 | -0.2060 | 0.0709 | [-0.345,-0.067] | 12 / 31 / 157 |
| 50 | `10300000 + 197*i` | 200 | -7.9680 | -8.1555 | -0.1875 | 0.0852 | [-0.354,-0.021] | 18 / 25 / 157 |
| 100 | `10200000 + 197*i` | 200 | -16.9325 | -17.2675 | -0.3350 | 0.1215 | [-0.573,-0.097] | 11 / 25 / 164 |

The descriptive sum of the three means changes from -29.3935 to -30.1220, a deterioration of 0.7285 under this 200-episode-per-horizon protocol. This is **not** the standard 1000-episode full validation. Every horizon's paired interval lies below zero, so the candidate was rejected before that expensive gate.

On 100-step episodes, the candidate executed 2.29 User2 Restores per episode on average, while v14 executed none. User2's visible compromise marker duration fell from 16.3 to 2.29 steps. Among the 35 episodes with a material return change, the candidate averaged 12.8 Restores and reached 18 in one episode; the worst return change was -9.8. Reduced marker duration accompanied worse total reward. Repeated Restore cost is a plausible contributor, but this experiment did not decompose each reward component.

## Interpretation and artifacts

The Meander repair does not transfer to B-line v14. A correct-looking local state gate can produce excessive repeated actions on a different opponent. This result supports opponent-specific diagnosis and a closed-loop cost/tail screen before historical promotion. It does not show that B-line has no other repairable weakness.

A fresh load through the ordinary cl-gym:rollout path exactly reproduced the experiment on the worst confirmation seed 10233687: v14 -9.1, candidate -18.9.

The v14 checkpoint remains untouched; no experimental candidate was promoted. Raw first-intervention traces, paired episode records, candidate file, and logs are under `/home/hardison/bes-artifacts/validations/bline-user2-first-restore-20261028/`. The shared scripts accept an explicit CAGE2 environment or red-agent name; their Meander defaults remain available.
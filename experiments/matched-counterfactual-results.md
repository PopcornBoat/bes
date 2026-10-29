# Matched official counterfactual screen: Level 2 result

The Level-2 screen used the frozen gen-463 Meander checkpoint and the five
Level-1 state/path groups. The nominations, collision rule, seed block,
opportunity rule, and analysis were committed in `f67aac0` before the full
official run. A separate two-seed smoke run checked replay mechanics and did
not enter the reported analysis.

## Execution and integrity

- Official environment: `Cage2-meander-100-v0`; 62-input stateless policy,
  fixed opening and fixed Controller decoy order.
- Fresh seeds: `12000000 + 197*i`, `i = 0..99`.
- Every group reached its cap of 20 distinct seed episodes: 100 matched
  opportunities in total. The unchanged incumbent consumed 10,000 official
  transitions; each intervention lane consumed another 10,000.
- For every pair, a digest of the simulator state and Python RNG state,
  plus the Controller state, observation, ranking, actions, rewards, and
  transition prefix, was replay-checked.
  Both nominated actions were feasible at the same state and changed the
  incumbent's concrete action. Each branch then ran to the 100-step end.
- Full event table SHA256:
  `bcafb341798227ed5ad8a992ac4843af48535afd9d8c02108760bc15211d815f`.
  Local artifacts are under
  `/home/hardison/bes-artifacts/validations/meander-matched-counterfactual-level2-20261029/`.

## Frozen primary comparison

The unweighted mean of the five group means for structural minus random
full-episode return was **-34.889**. The seed-cluster bootstrap 95% interval
was **[-62.078, -18.013]**, conditional on these five groups and this one
frozen random nomination draw. Structural branch minus incumbent averaged
**-34.345** over the 100 matched events; random branch minus incumbent
averaged **+0.544**. Structural branches were positive/negative/tied on
4/91/5 events; random branches on 29/44/27.

| Group | Terminal, target state | Structural action | Random action | Mean structural - incumbent | Mean random - incumbent | Mean structural - random |
| --- | --- | --- | --- | ---: | ---: | ---: |
| 0 | TEAM-0-33, User2 `0001` | User2 Analyse | User2 Restore | -72.770 | +5.605 | -78.375 |
| 1 | TEAM-0-7, User3 `0001` | User3 Remove | User3 Analyse | -7.340 | -0.100 | -7.240 |
| 2 | TEAM-0-7, Enterprise0 `0000` | Enterprise0 Remove | Enterprise0 Decoy | +0.150 | -0.560 | +0.710 |
| 3 | TEAM-0-156, User2 `0001` | User2 Analyse | User2 Decoy | -90.715 | -2.175 | -88.540 |
| 4 | TEAM-0-7, User4 `0000` | User4 Restore | User4 Remove | -1.050 | -0.050 | -1.000 |

All rows have 20 paired episode opportunities. The actions are Semantic-36
categories; the Controller resolved them to concrete official actions for
the one-step intervention.

## Interpretation

This frozen Level-2 test **does not support** the current structural
nomination rule as a way to allocate official action-screening budget. Its
User2 support deficit was real, but the Level-1 score tied Analyse, Remove,
and Restore on that target. The deterministic action-index tie-break picked
Analyse, whereas the random control picked the known useful Restore in group
0. In group 3 it picked Decoy, which was also substantially less harmful
than Analyse on these matched states. Thus the audit can identify an
under-supported **target/path** without identifying a beneficial **response**.

The result is a calibration finding, not proof that random nomination is
generally better. It conditions on one random draw, only five groups from a
known checkpoint, and single-step interventions followed by the unchanged
incumbent. It does not estimate the return of a learned specialist or a
deployed policy. No genotype was modified and no Level-3 synthesis ran.

The next design decision is to improve response-specific nomination using
information independent of the known User2 answer, then freeze a new rule
and test it on fresh checkpoints. Re-ranking this same cohort after seeing
these returns would leak the positive control into the discovery rule.

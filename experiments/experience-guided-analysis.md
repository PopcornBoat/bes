# Official experience analysis: read-only first stage

## Independent assessment

This proposal is technically feasible and scientifically useful as a **nomination** mechanism. It is not a source of action advantages by itself. An action's observed return-to-go is confounded by the policy that chose it, the other 58 policy inputs omitted from a four-bit host group, hidden CybORG state, Controller availability, episode phase, and subsequent actions. Consecutive steps in one episode are correlated. The cheapest valid test of the central hypothesis is therefore to compare several nomination lanes against an equally eligible random lane under the same official intervention budget, then validate any resulting policy separately.

The strongest simpler baseline is the existing structural-opportunity audit plus independent official response screening. It already nominated the Meander User2 Restore positive control and rejected a B-line transfer. The new analysis earns its cost only if return, persistence, or history evidence improves the **hit rate per official transition** beyond structural coverage alone. A large persistent database is premature until this comparison succeeds.

## Audit of the maintained implementation

| Requirement | Existing source or gap | First-stage treatment |
| --- | --- | --- |
| Official rollout and reward | `official-counterfactual-pilot.lisp` records each genuine CAGE2 step, reward, 62-value policy observation, pre/post Controller state, ranking, and concrete action | Reused; added explicit termination/truncation to its in-memory records |
| Path, terminal team, learner, Top-8, feasibility | `structural-opportunity-audit.lisp` writes `steps.tsv` for policy steps 3–99 | Reused without changing its schema or policy execution |
| Opening rewards, actual concrete action, Controller context | Present in pilot records but absent from `steps.tsv` | New compact `executions-v2.tsv` sidecar for all steps, including fixed opening 0–2 |
| Policy and environment identity | Runner writes checkpoint SHA-256 in `input-sha256.txt`; environment was only a command argument | Analyzer uses checkpoint hash; new `environment.txt` verifies environment name |
| Global action support | Can be computed from the frozen graph | New `global-support.txt`, separate from active-path masks |
| Return-to-go | No persistent episode RTG table | Analyzer reconstructs undiscounted suffix sums and checks full reward sum against official episode total |
| Multiple workers | Separate audit directories already supported | Analyzer merges directories, rejects duplicate `(environment, checkpoint SHA, seed)` episodes |

The active specialist training loop already runs independent frozen-incumbent official audits periodically. This first stage analyzes **those audit rollouts**, not every candidate evaluation or every official transition in the main training loop. It does not change reproduction, grouped epsilon-lexicase, official racing, promotion, Controller resolution, serialized genotypes, or the 62-input policy. A process may write one audit directory; separate workers must use separate directories. Incomplete episodes fail accounting checks rather than silently entering the analysis.

Prior experiments matter. `docs/patch-evidence.md` records no demonstrated promotion from signed bid edits, Top-k substitution, targeted routing, specialist composition, or paired local credit in their tested forms. `experiments/structural-opportunity-audit.md` and `experiments/response-sweep-results.md` describe the positive control and the limits of one-step intervention. This analyzer does not recycle those mutation rules or treat teacher labels as online evidence.

## Minimal implementation

- `official-counterfactual-pilot.lisp`: termination/truncation are retained in each rollout step.
- `structural-opportunity-audit.lisp`: writes an episode-append, versioned execution sidecar plus environment and global-support metadata. `proposed_index` is the TPG Top-1 semantic proposal; `selected_index` is the Controller-resolved semantic pair. The concrete action is checked against the actual action reported by the environment. No observation is duplicated in the sidecar.
- `scripts/analyze-official-experience.py`: read-only standard-library analyzer. It checks 62 inputs, action indices, reward totals, Controller scan/step agreement, proposal/ranking agreement, episode boundaries, and worker uniqueness. It reports three separate lanes: observational return, limited action coverage, and repeated negative-reward behavior. Previous executed action is used only for a diagnostic history split; it is never a runtime TPG input.
- `tests/test_official_experience.py`: accounting, proposal/environment mismatch, missing alternative evidence, legacy partial logs, and duplicate-worker rejection.

The state-group key is `(checkpoint SHA, terminal team, phase, target host, exact four host bits)`. Every policy step can occur in several host-context groups, so **group counts are not independent decisions**. A group requires at least five distinct episodes; each action estimate first averages repeated steps within an episode. The observational lane subtracts the policy's same-step average return-to-go before comparing actions to remove the trivial remaining-horizon trend. This does **not** remove action-selection or hidden-state confounding. All nine host targets and all 36 semantic actions follow the same rule. No known successful action is hardcoded.

The analyzer writes every eligible coverage action, not just the first tied candidate. Global support, active-team reachability, Top-8 presence, Controller feasibility, and execution are separate fields. Controller-unavailable actions are not nominated. A coverage gap is a reason to inspect an action, never an estimate of its value. The repeated-negative-reward lane records an actual contiguous example span and the next observed action; negative reward is not attributed to the repeated action without intervention.

## Verification and first findings

The six accounting tests pass. The modified Lisp audit loaded and completed 10 genuine official episodes each for frozen Meander v9 and B-line v14. The analyzer also merged four distinct Meander v9 worker directories (40 episodes) and read older 100-episode audit logs as explicitly partial data. Full-sidecar episodes reproduced the official episode return exactly within numeric tolerance. In one 10-episode audit, the sidecar was approximately 148 KiB beside a 636 KiB structural trace.

| Audit | Episodes | Full return verified | Host-context groups with 5+ episode exposure | Groups with two observed actions, each in 5+ episodes | Exact 62-input groups with that overlap |
| --- | ---: | ---: | ---: | ---: | ---: |
| Meander v9, four worker directories | 40 | 40 | 234 | 72 | 0 |
| B-line v14, new v2 audit | 10 | 10 | 92 | 9 | 1 |
| Meander v11, old audit | 100 | 0 | 286 | 93 | 4 |
| B-line lineage incumbent, old audit (different checkpoint SHA) | 100 | 0 | 466 | 176 | 25 |

Old audits lack opening rewards and verified concrete execution, so their suffix values are usable only as partial diagnostics. Both frozen v9/v14 graphs contain all 36 actions somewhere. Yet only 18 of 36 semantic actions were executed in the 3,880 recorded Meander v9 policy steps, and 12 of 36 in 970 B-line v14 steps. This is an **active-policy coverage** observation, not proof that the other actions should be used.

Controller resolution matters. In the new version-2 audits, the resolved pair differed from TPG Top-1 on 34/970 Meander steps and 455/970 B-line steps. The first three fixed-opening steps have no TPG proposal and are excluded from this count. A study that equates TPG proposal with executed action would therefore be materially wrong, especially on B-line.

For the frozen B-line v14 policy, Op_Server0 Decoy (index 35) was Top-1 on 394/970 policy steps but was the resolved action on only 40. On 296 steps it fell through to Enterprise0 Analyse (index 4); index 35 was Controller-infeasible on all 296. This identifies a substantial proposal/execution mismatch, not an established reward loss: the Controller's fallback may be the intended behavior after Decoy options are exhausted. An earlier official response sweep on the **same checkpoint SHA** found Enterprise0 Restore in host state `1000` worse by -4.0 on its 20-episode confirmation cohort, and User2 Restore in `0000` worse by -1.0. These two visible coverage gaps should not be treated as promising repairs merely because they are underused.

The known User2 Restore action is catalogue index **18** and was executed 38 times in 3,880 Meander v9 policy steps. It appears in 26 eligible coverage groups. In the User2 `1101` context at terminal `TEAM-0-1`, it was feasible, reachable, and present in Top-8 across 37 episodes yet was never selected in that group. This is a context-specific **ranking/execution** gap, not global absence of the action. **The generic coverage ranking did not prioritize this relevant abnormal-state group reliably**: normal `0000` host contexts dominate the top scores. This is a negative result for the current generic ranking, despite the known intervention positive control. The current score should not be tuned after seeing this result and then described as an unbiased discovery.

Observational return associations are too weak for a repair decision. In the 40-episode Meander audit, the largest adjusted association arose from a broad normal-host context with only six alternative-action episode exposures. The same policy steps appear under multiple host-context keys, and there is no exact-62 action overlap at the five-episode threshold. The return lane therefore yields hypotheses, **not a ranked action advantage**. B-line has only one exact-62 overlap group in the new 10-episode audit. Larger counts in the old 100-episode audits do not cure Controller and hidden-state confounding.

Repeated negative-reward spans occur across independent episodes, but negative per-step reward is common in CAGE2 and does not establish that an alternative action would improve the trajectory. The backward lane records possible intervention points; it has not demonstrated a delayed correction mechanism. Previous-concrete-action splits produced observable broad-group differences, but no matched full-62 comparison shows that history resolves policy-relevant aliasing. There is no basis yet to add runtime history or memory.

## Next official experiment

Freeze the current analyzer, then compare its three nomination lanes and an **eligible random control** on new checkpoints. For each sampled state group and active path, use the same Controller-feasible alternative set and the same independent official intervention budget. Replay and verify the exact baseline prefix and Controller state, change one action, then continue the frozen incumbent. Keep discovery, confirmation, and promotion seeds separate. Count independent episodes and official transitions, not only candidate wins. Include known Meander User2 Restore and B-line transfer as engineering controls, but evaluate general discovery on other checkpoints not used to design the rules.

First measure `confirmed positive opportunities / official transition` and false-positive rate by lane. If coverage-only or random performs as well as the combined analysis, avoid building a larger experience database or specialist injector. If a lane consistently improves discovery efficiency on held-out policies, then test conditional specialist synthesis and full-policy validation. The one-step intervention result alone cannot certify a heritable policy improvement.

## Reproduce

```bash
python3 scripts/analyze-official-experience.py \
  /home/hardison/bes-artifacts/runtime/experience-guided-audit-v9-20261104 \
  /home/hardison/bes-artifacts/runtime/experience-guided-audit-v9b-20261104 \
  /home/hardison/bes-artifacts/runtime/experience-guided-audit-v9-final-20261104 \
  /home/hardison/bes-artifacts/runtime/experience-guided-audit-v9-v2-20261104 \
  --environment Cage2-meander-100-v0 \
  --output /home/hardison/bes-artifacts/runtime/experience-guided-analysis-20261104/meander-v9-combined-40.json
python3 tests/test_official_experience.py
```

The first-stage result establishes accounting and a way to generate inspectable hypotheses from genuine official experience. It has **not** established that observational return differences are causal, that these lanes beat random nomination, that User2 Restore would have been found without the earlier experiment, or that a new TPG offspring improves official return.

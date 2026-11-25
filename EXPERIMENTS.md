# Reproducible experiments

The [validated BES pipeline](docs/validated-pipeline.md) maps the full sequence from offline learning and DAgger to teacher-free online evolution and the final pure-graph score. It links each retained method to its measured effect and evidence.

## Reference checkpoints

Frozen B-line and Meander checkpoints, checksums and official full-validation scores are listed in [validated-checkpoints/README.md](validated-checkpoints/README.md). Do not overwrite these files. Record the checkpoint hash, controller protocol, opponent, seed root and horizon for each comparison.

## Default full validation

For complete-agent scores, follow the official CAGE2 Scenario2 and ChallengeWrapper
evaluation loop. Set Python random.seed(153) once per agent run. Use one environment
per horizon/opponent cell and call the wrapper's ordinary reset() between episodes.
Run 1,000 episodes for each combination of 30, 50, and 100 steps with B-line, Meander,
and Sleep. Sum the nine cell means. Record the CybORG commit and policy hashes with
the score. Use an explicit override for other seed roots or reset protocols.
The earlier explicit per-episode simulator seed workflow is a separate protocol used
for paired experiments. Equal root numbers across these protocols do not identify
the same cohort.

## Commands

Run the maintained tests:

```bash
scripts/bes-test
scripts/bes-test --core
```

Check local environment paths:

```bash
scripts/bes-doctor
```

Launch teacher-free official training from the protected reference checkpoint:

```bash
scripts/run-bline-official-online /home/hardison/bes-artifacts/runtime/bline-online-run
scripts/run-meander-official-online /home/hardison/bes-artifacts/runtime/meander-online-run
```

Run one launcher for the desired opponent and pass a new or empty run directory. The B-line launcher uses frozen v14 and port 8083. The Meander launcher uses frozen v9 and port 8082. Each writes its request and logs into the run directory. Use independent full validation and fresh seeds to assess a promoted checkpoint; generation best, imitation score and mixed return alone are not official validation.

## Teacher-guided DAgger

From the `offline-dagger` worktree, start a BES server with `scripts/bes-runtime start`. Submit an opponent-specific request with `scripts/bes-search submit REQUEST.sexp`.

- B-line v14 route uses `experiments/evolved-candidate-official-admission.sexp` to warm-start from the protected v13 checkpoint.
- Meander v8 route uses `experiments/meander-heuristic-official-guided.sexp` to start a fresh heuristic-guided population.

Check the input checkpoint path (if applicable) and set a separate output directory in the request before submitting it. The Lisp mode name for these DAgger requests is `:official-guided`. The teacher-free launchers select `:official-online`.

## 2026-11-16 — BES opponent recognition and dispatch

Official CAGE2 Scenario2 with ChallengeWrapper, seed root `153`, 1,000 episodes for each opponent and horizon. The Controller executes `51 → 116 → 55`, calls the frozen 62-input TPG classifier at decision index 3 and dispatches the selected expert for the rest of the episode. The classifier SHA-256 is `8864b37e6b3a80536cf2246df508182a3adc849e16cfb37e2e143bd3da87c834`.

| Dispatched policy | 30 steps | 50 steps | 100 steps | Sum |
| --- | ---: | ---: | ---: | ---: |
| B-line automatic Restore repair | -4.2936 | -7.5297 | -15.2746 | -27.0979 |
| Meander v14 manual fix | -5.4771 | -8.7346 | -16.4665 | -30.6782 |
| Sleep | 0 | 0 | 0 | 0 |
| **Combined** | | | | **-57.7761** |

All 9,000 episodes were routed correctly. The 360,000 B-line and Meander concrete actions and 6,000 episode returns matched their standalone references. Dispatch with the frozen B-line v14 and Meander v9 baselines scored `-60.8513`. With the experimental repairs it scored `-57.7761` on the same schedule, a gain of `+3.0752`. Meander seed `5925838` moved from `-368.3` to `-18.1`.

The B-line expert uses its automatic previous-observation Restore guard and Cardiff global Decoy schedule. The Meander expert uses its TPG graph, the frozen route catalogue and the Meander Cardiff global schedule. The catalogue was built using root `153`, so this run establishes end-to-end reproduction on `153`. Independent-root validation of the combined system remains open. The local Cardiff `90000.pth` full run scored `-57.5474` under the original evaluation loop. The difference of `0.2287` is descriptive because the runs use different episode seeding protocols.

WSL artifacts are under `/home/hardison/bes-artifacts/runtime`. See `bes-opponent-dispatch-best-20261116/full/results.json` for the per-cell results and comparison against the standalone experts, `full/plan.json` for source checksums and episode seeds, and `bes-opponent-dispatch-full-20261116/full/results.json` for the baseline dispatch run.

## 2026-11-16 — Pooled observable contexts for automatic priority repair

This teacher-free pilot started from the standalone B-line auto-node and Meander User2 automatic repair graphs. It nominated candidates from official incumbent archives, learned small predicates over the existing 62 inputs, and tested single-action replacements followed by the frozen parent on independent official episodes. The activity was scoped to 100-step opportunity confirmation before graph synthesis.

| Opponent | Discovery forks | Confirmed proposals | Official transitions | Candidates advanced |
| --- | ---: | ---: | ---: | ---: |
| B-line | 100 | 2 × 20 independent episodes | 77,900 | 0 |
| Meander | 110 | 3 × 20 independent episodes | 82,800 | 0 |

B-line confirmation mean paired deltas were `0.000` and `-0.750`. Meander deltas were `-0.925`, `-55.345`, and `-1.475`. Pooling obtained 20 independent episodes per shortlisted Meander candidate and included observation patterns absent from discovery. The Enterprise1 Restore → User0 Remove substitution caused three new catastrophes and deferred Enterprise1 Restore by exactly one step in all three. The additional Op_Server0 losses were 144, 452, and 342. The two other Meander candidates also lost on average. No graph advanced to new closed-loop validation, and historical bests remained protected.

See `/home/hardison/bes-artifacts/runtime/pooled-context-repair-20261116` for the plans, paired trajectories and per-opponent results. Reported transition counts cover the pilot and omit the 800 integration-smoke transitions per opponent.

## 2026-11-16 — Protected Restore and loss-window priority search

The teacher-free pilot kept evidence-backed incumbent Restore contexts eligible for retention, then nominated changes around Op_Server0 and Enterprise2 loss windows in Meander and recurring small host losses in B-line. Discovery paired each perturbed episode with the same frozen parent and reserved ordinary contexts for comparison. B-line spent 16,800 transitions on 90 interventions across nine candidates. Meander spent 5,600 on 30 interventions across three candidates. Neither produced a shortlist or a new graph. These costs exclude the integration smoke tests and the separate tail diagnostic.

In a retrospective 800-transition diagnostic on Meander seed `1433411182`, the standalone automatic parent scored `-184.8`. Enterprise2 loss first appeared at step 82 and Op_Server0 loss at step 86. At step 83, the policy chose Enterprise0 Analyse while all Enterprise2 actions were absent from Top-8. Replacing it once with Enterprise2 Analyse scored `-27.8`; Enterprise2 Restore scored `-25.8`; Enterprise2 Remove reproduced `-184.8`. Op_Server0 Restore at step 86 scored `-53.8`. Each branch continued with the frozen parent. These are conditional effects on one retrospectively selected trajectory. A general-purpose repair requires independent confirmation that includes normal contexts with the same visible evidence.

See `/home/hardison/bes-artifacts/runtime/protected-priority-search-20261116` for the plans, results and paired traces.

## 2026-11-16 — Automated Semantic-36 search and Enterprise2 replication

For each Red agent, the search enumerated executable alternatives across all 36 semantic actions from 1,512 archived episodes, scheduled 40 observable context groups over two fresh screening batches, and built four TPG graphs for independent paired 30/50/100-step evaluation. B-line spent 192,900 official transitions and Meander spent 183,900. No candidate advanced. All eight graphs changed executed actions in the 100-step cohort and increased Restore usage. The best sums of paired horizon differences were `-0.070` for B-line and `-0.047` for Meander. B-line's strongest one-action screen mean was `+3.000` on eight episodes, while its complete graph changed the sum by `-0.220`.

On 15 additional Meander episodes with the observed Enterprise2 scan condition, one-step Enterprise2 Analyse tied in every episode. Restore averaged `-1.260`, with one win, one tie and 13 losses. Three episodes shared the disaster's full 62-dimensional observation and incumbent action. Analyse tied in all three, and Restore cost one point in each. The five separate fresh-seed screening matches also tied for Analyse and averaged `-1.400` for Restore. The replication used 4,500 official transitions and produced no graph. The one retrospectively selected disaster had shown gains of `+157` and `+159` respectively.

Artifacts are under `/home/hardison/bes-artifacts/runtime/automatic-priority-search-20261116`. The transition totals exclude smoke tests.

## 2026-11-18 — Direct closed-loop priority racing

Complete offspring entered official racing immediately after compilation. Each opponent started with 24 candidates on 20 shared 100-step seeds. Eight candidates advanced to 40 independent 100-step seeds and three reached independent confirmation on 100 episodes per horizon. Each opponent used 158,000 official transitions excluding smoke. The incumbent return was reused within each stage. Episode traces record Restore changes at the first concrete-action divergence and later in the episode.

B-line candidate `auto-3636150cc3` replaces User4 Analyse with User3 Analyse on one archived observation. Its 100-step mean advantage was `+0.200` in each of the three stages. Final mean deltas at 30/50/100 steps were `0.000 / -0.040 / +0.200`, a sum of `+0.160`. At 100 steps it won four and tied 96 episodes. Reward decomposition showed ten fewer net Restore actions and 10 fewer host-loss points across the 100 pairs. Four fewer points in one 50-step episode offset part of the long-horizon gain. This is a pilot survivor awaiting full validation. SHA-256 is `ab48da08e92b30a99d1b86b347cbd9dc8e9f7e8a3032abc8efacd22dba31871b`.

Meander produced no survivor. A broad User2 Restore priority condition passed the 40-episode screen with `+0.9675`, then lost `-4.779` across horizons in confirmation. It added `1.48` net restores per 100-step episode and produced a new catastrophic paired loss of `184` points at seed `2036357730`. The neutral Meander candidate changed concrete actions in all 300 confirmation episodes and tied every return.

Artifacts are under `/home/hardison/bes-artifacts/runtime/closed-loop-priority-racing-20261118/full`. See each opponent's `confirmation/restore-events.tsv` and `confirmation/paired-episodes.tsv` for the audit.

## 2026-11-18 — B-line closed-loop survivor full validation

Frozen candidate `auto-3636150cc3` and its parent `bline-auto-node` were evaluated on 1,000 shared fresh seeds at each of 30, 50, and 100 steps, using disjoint seed blocks and seed root `20261118072`. The official paired run used 360,000 transitions. The mean totals were `-26.8766` for the parent and `-26.8726` for the candidate. The paired difference was `+0.0040`, with an approximate 95% interval of `[-0.0646, +0.0726]`. Mean differences by horizon were `0.000 / +0.002 / +0.002`. The 100-step cohort had 14 wins, 18 losses and 968 ties. Its worst 10% mean moved from `-25.365` to `-25.155`, with zero new episodes below `-100` at any horizon.

In the 100-step cohort the candidate changed the concrete action sequence in 46 episodes. It netted five additional Restore actions and seven fewer host-loss points, for two reward points gained over the 1,000 pairs. The pilot's net Restore savings and `+0.200` long-horizon mean advantage did not replicate. Retain `bline-auto-node` as the incumbent.

Artifacts, including the frozen input graphs, plan, per-episode pairs, Restore events, and results, are under `/home/hardison/bes-artifacts/runtime/bline-closed-loop-survivor-full-20261118`.

## 2026-11-18 — Decision-window offspring and Enterprise2 tail validation

The window miner used first-visible-threat, repeated host-loss and repeated Restore histories to nominate stateless 62-input graph edits. B-line entered 16 whole offspring and Meander 12 into paired racing. Independent 100-episode-per-horizon confirmation retained two B-line pilot candidates. `auto-35b70ccf6b` replaces User4 Remove with User2 Analyse on three archived inputs. Its 30/50/100 differences were `-0.130 / +0.040 / +0.170`, total `+0.080`, approximate total CI95 `[-0.1639,+0.3239]`. `auto-f3ad4823d3` instead selects User2 Remove on those inputs. Its differences were `-0.090 / +0.040 / +0.180`, total `+0.130`, approximate total CI95 `[-0.1087,+0.3687]`. These are small-sample candidates awaiting full validation. The repeated-Restore rule yielded no candidates because all 5,227 recent repeats at Meander Enterprise1/User2 had new visible compromise evidence in between. Meander's window candidates did not pass. Official transitions were 146,400 for B-line and 136,800 for Meander, excluding smoke.

The separately frozen Meander Enterprise2 Analyse graph was tested on 1,000 fresh 100-step paired episodes. It changed 14 episodes, won one and tied 999, with no observed negative paired returns. Parent mean was `-17.838`; candidate mean was `-17.431`, delta `+0.407`, SE `0.407`. The entire gain came from independent seed `2082466566`, improving `-423.3` to `-16.3`. The graph first selected Enterprise2 Analyse instead of Enterprise0 Analyse at step 45. It reduced Enterprise2 loss by 47 and Op_Server0 loss by 364, with four net additional Restore actions. Worst-10% mean moved from `-31.025` to `-27.030`. This is an independent replication of a rare beneficial intervention family with an uncertain overall mean effect. It does not establish the immediate information mechanism or guarantee safety on untested seeds. Candidate SHA-256 is `3b9c6a4f11ffdbc28551c3eb65201a333b4ce8c8f2b8ad225659c6ee22459010`. The tail comparison used 200,000 official transitions. Runtime input and Controller contracts remain the existing ones.

Plans, genotypes and paired trajectories are in `/home/hardison/bes-artifacts/runtime/decision-window-repair-20261118/full`. The baselines are the standalone automatic B-line and Meander parents. The manual route-based combined policy scoring `-57.7761` is a different experimental policy.

## 2026-11-18 — Independent full validation of window repairs

Frozen B-line candidates were evaluated with their actual automatic parent on 1,000 paired episodes at each horizon. The parent total was `-26.8062`. The User2 Analyse candidate scored `-26.5932`, paired delta `+0.2130`, approximate CI95 `[-0.0676,+0.4936]`. One seed, `2096677859`, improved from `-148.7` to `-13.7` and supplied 135 of the 161 points gained in the 100-step cohort. The User2 Remove candidate scored `-26.7122`, paired delta `+0.0940`, nominal CI95 `[+0.00092,+0.18708]`. Its horizon differences were `+0.034 / +0.033 / +0.027`. The marginal interval is unadjusted for testing two candidates. It retained the parent's catastrophic episode. Neither result automatically changes the historical incumbent. Official interactions were 540,000.

The frozen Meander Enterprise2 Analyse candidate completed two independent blocks, each with 250 paired 30-step, 250 paired 50-step and 2,000 paired 100-step episodes. Block A's 100-step delta was `+0.0525`, from one improvement of 105 points at seed `2102906081` (`-123.6` to `-18.6`). Block B's delta was `+0.0055`, from one improvement of 11 points at seed `2108539513` (`-41.1` to `-30.1`). All other paired returns tied, including all short-horizon returns. The candidate changed concrete action sequences in 27 and 12 long episodes respectively. Across the 4,000 new long episodes, there were two wins, 3,998 ties and zero losses; pooled mean delta was `+0.0290`. The 880,000 official interactions additionally covered 1,000 short-horizon pairs.

Including the preceding independent 1,000-episode check, the same frozen Meander graph has 5,000 evaluated 100-step pairs, three wins and zero observed losses, with total gain 523 and mean `+0.1046`. Two episodes below `-100` were avoided. Tail improvement has recurred on independent roots, while the expected gain remains imprecise because benefits are rare.

Results, exact seeds, frozen input graphs and paired action/Restore logs are under `/home/hardison/bes-artifacts/runtime/window-repair-full-validation-20261118`. Parent identities are the automatic standalone policies, distinct from the previously evaluated manual route combination.

## 2026-11-20 — Complete-agent evaluation and action-frequency report

The frozen BES Controller used the TPG opponent classifier, B-line automatic Restore guard and Meander v14 manual fix. Cardiff used the original MainAgent with the local B-line and Meander `90000.pth` weights. Both complete agents used the default full validation protocol on patched CybORG 2.1 (`26ce1c1253fa9e2e73f25e6a7f2da32860c11257`). Each evaluated all nine cells, routed 9,000 of 9,000 episodes correctly and executed 540,000 official transitions.

| Sum of the 30-, 50- and 100-step means | BES | Cardiff 90000 | BES minus Cardiff |
| --- | ---: | ---: | ---: |
| B-line | -26.9913 | -26.9103 | -0.0810 |
| Meander | -31.0884 | -30.6371 | -0.4513 |
| Sleep | 0.0000 | 0.0000 | 0.0000 |
| **Total** | **-58.0797** | **-57.5474** | **-0.5323** |

The previous `-57.7761` BES result used the same full dispatch configuration and matching frozen inputs with explicit per-episode simulator seeds. The official sequential-reset run sampled different trajectories. The new Controller adapter reproduced all 5,760 archived concrete actions across 96 earlier episodes. At 100 steps, the new Meander cohort had one `-297.3` episode. Replacing it with the mean of the other 999 episodes would add `0.2806` to the total. The reported score includes all episodes.

The action charts exclude the fixed three-step opening. At 100 steps, the B-line Controller executed a different host/response pair from the effective Top-1 on 45,660 of 97,000 decisions (47.1%). Meander's frozen manual catalogue changed 31,878 of 97,000 native Top-1 proposals (32.9%). In the catastrophic Meander episode, steps 77 through 99, indexed from zero, all executed Defender Remove and each returned `-12`. The native and repaired Top-1 agreed with execution on those steps. Five other episodes also executed at least 23 consecutive Defender Remove actions without a similarly large single-step loss. This identifies a priority conflict to investigate with observation and trajectory context.

Artifacts are in `/home/hardison/bes-artifacts/runtime/full-agent-validation-20261120`. The Windows report is at `D:/PhD-researches/bes-artifacts/reports/full-agent-validation-20261120/index.html`, with the TPG wins versus execution and TPG versus PPO action pies.

## 2026-11-21 — Competition-era CybORG reproduction

The unmodified competition checkout `f12ff493cd3b8327cab93f645d71330e7b282377` was evaluated in a separate Git worktree with the default root-153 full validation protocol. The checkout precedes the two simulator fixes described in [Reward Shaping for Happier Autonomous Cyber Security Agents, section 5.1](https://chrishicks.io/assets/pdf/Happy_AISec2023.pdf). All three complete Agents routed 9,000 of 9,000 episodes correctly. The three historical-version runs used 1,620,000 official transitions, plus 3,240 for smoke.

| Complete agent | Competition environment | Patched environment | Competition minus patched |
| --- | ---: | ---: | ---: |
| Cardiff MainAgent, published `model.pth` | **-54.5744** | -86.6026 | +32.0282 |
| Cardiff MainAgent, local `90000.pth` | -57.0415 | **-57.5474** | +0.5059 |
| BES Controller, frozen combined policy | -58.3578 | -58.0797 | -0.2781 |

The old-environment published weights reproduced the leaderboard score of `-54.57` at its reported precision. B-line accounted for `31.8873` of the `32.0282` total difference for those weights. The local `90000.pth` run remains the Cardiff benchmark in the patched environment. BES had one 100-step Meander episode below `-100` in each version (worst `-911.6` in the competition checkout and `-297.3` in the patched run). The version comparison uses archived patched runs and the same evaluation protocol, with no episode-level pairing claim.

Artifacts are in `/home/hardison/bes-artifacts/runtime/cage2-competition-validation-20261121`. The Windows report is at `D:/PhD-researches/bes-artifacts/reports/cage2-competition-validation-20261121/index.html`. Per-cell means, tails, dispatch and policy hashes are recorded in the results and manifests.

## 2026-11-21 — Meander manual patch from a matched PPO trajectory

Status: diagnosis and default full validation completed. The frozen 11-rule candidate scored -57.8442, compared with -58.0797 for the frozen incumbent and -57.5474 for Cardiff 90000.

The diagnostic replays the completed BES evaluation's action prefix, verifying the recorded rewards, to recover the start of Meander 100-step episode 324 (zero-based, archived return `-297.3`). At that same simulator state and RNG state, run the original complete BES Controller and Cardiff MainAgent with local `90000.pth`. Freeze disagreements as `(62-value policy input, Controller decoy mask, BES concrete proposal) -> Cardiff concrete action`. The rule catalogue is used only in the Meander expert after dispatch and uses no PPO actor at runtime. The smoke test verified that the frozen rules reproduce the PPO actions and reward sequence for a separate 100-step diagnostic.

The runner first checks that the frozen candidate reproduces the improved Cardiff trajectory on the discovery episode, then evaluates the whole BES agent under the default full validation protocol. The root-153 validation reuses the discovery root and tests whole-agent performance across the matrix. The exact same-start discovery comparison is reported separately. An independent root is needed to establish generalization. The patched-environment comparison target is `-57.5474`.

The exact same-start diagnostic moved the original -297.3 episode to -19.5, matching all 100 Cardiff actions and rewards. The frozen table SHA-256 is 1b5a9cf5b00f7347465c99d44bc5184559a9b03eff8a1a696591d39746aced25. The whole-agent total improved by +0.2355 and remained 0.2968 below Cardiff. Meander changes at 30/50/100 steps were +0.0026 / -0.1433 / +0.4307. At 100 steps, worst-10% mean improved from -28.836 to -23.999 and the worst episode from -297.3 to -29.7. The rule fired 294 times and only in Meander. The candidate had no episodes below -100.

The full streams first differed at Meander 30-step episode index 65, step 3. B-line rules never activated, yet the later B-line mean scores changed. The continuous RNG stream allows changes in one episode to affect subsequent draws. Episode indices after the divergence therefore do not establish paired identity. The full-run Meander 100-step episode index 324 scored -23.9 and should not be presented as the exact rescue, which is established by the separately reproduced start. No historical-best promotion was made.

Run directory: `/home/hardison/bes-artifacts/runtime/meander-ppo-manual-patch-20261121`. Monitor `progress.log`. The runner records `diagnostic.json`, the frozen `meander-manual-routes.sexp`, and full per-episode logs and scores when available. Launcher: `scripts/meander_manual_route_validation.py` in the WSL `analysis/policy-action-frequency` worktree.

## 2026-11-22 — Ten-root validation of ranked Decoy host scheduling

Harry completed 20 whole-agent full validations on patched CybORG 2.1. Both arms used the same frozen opponent router, B-line checkpoint, Meander checkpoint, and external ranking logic. Both used the default ranked Decoy host scheduler. The only treatment was the local Op_Server0 Decoy order. Each arm ran once on each of 10 fresh seed roots, with 1,000 episodes for each B-line, Meander, and Sleep horizon at 30, 50, and 100 steps. The official continuous reset stream makes the full validation root the unit of pairing. Episode indices after a trajectory difference do not establish pairing. The 20 full runs totalled 10,800,000 official transitions, excluding smoke.

| Arm | Op_Server0 Decoy order | Mean total | SD across roots | B-line subtotal | Meander subtotal |
| --- | --- | ---: | ---: | ---: | ---: |
| A | HarakaSMTP, Apache, Tomcat, Vsftpd | −57.06690 | 0.33110 | −25.92942 | −31.13748 |
| B | HarakaSMTP, Vsftpd, Apache, Tomcat | −57.00277 | 0.27848 | −26.07480 | −30.92797 |

The paired mean difference (B minus A) was +0.06413, SE 0.07847, with a root-level 95% t interval [−0.11338, +0.24164], six wins and four losses. Sleep scored zero throughout. B gained +0.20951 on Meander and lost 0.14538 on B-line. Over 10,000 100-step Meander episodes per arm, the mean of each root's worst 10% improved from −27.5945 to −26.4184 and returns below −100 fell from nine to six. The worst Meander return nevertheless fell from −473.0 to −497.5. B-line episodes below −100 went from one to two. The test supports keeping A as the default local order. B has a small point-estimate advantage with uncertainty in both directions.

The ranked host scheduler uses the graph's semantic rankings, the fixed Decoy option order, and the Controller's used-option state. The frozen whole-agent results also include the Meander semantic ranking lookup in `meander_routes.sexp`, which keys on the 62 policy inputs and remaining-Decoy counts and falls back to an observation-only key, and the frozen B-line context guard in `bline_guard.sexp`. The optional concrete-action replacement table was disabled in all 20 worker manifests. For 100-step Meander alone, pre- and post-override Top-1 histograms establish that at least 30.3% of post-opening Top-1 proposals changed in each arm. This is a lower bound on proposal changes, with delivered action changes measured by a different quantity. Reproducing the measured configuration requires its external Meander route table. A graph-only score would require a separate evaluation.

Harry run directory is `/home/hagrid/bes-deploy/ranked-decoy-ten-roots-20261122/out`. Artifacts are in `D:/PhD-researches/bes-artifacts/reports/ranked-decoy-ten-roots-20261122` with the seed plan, per-worker manifests and scores, paired CSV, and comparison figure. The scheduler's repository implementation was synchronized separately. Neither the frozen checkpoint nor the local Decoy order was changed by this comparison.

## 2026-11-23 — All-host local Decoy permutations with frozen program graphs

Harry evaluated 117 tables on patched CybORG 2.1 with the ChallengeWrapper, root 153, continuous resets and 1,000 episodes per opponent and horizon. Each table used the same frozen B-line and Meander v15 graphs, TPG opponent router, and three-action opening. The ranked Decoy host scheduler kept the Top-8 host order. Each treatment permuted one existing host-local list, shared by both experts. Runtime decisions used the graphs and Controller. The sweep used 63,180,000 official transitions, excluding smoke.

The pure-graph baseline reproduced **−57.2553**, including the archived concrete actions and episode returns. The champion changed only Enterprise0 from `[2, 6, 7, 0]` to **`[6, 7, 2, 0]`** (Tomcat, Vsftpd, HarakaSMTP, Apache) and scored **−56.7823**. This gained **+0.4730** over the pure baseline and **+0.1390** over the earlier root-153 guard result. A separately launched root-153 replay reproduced the champion's full action and episode-return files byte for byte. Five additional full validations used 2,700,000 official transitions.

| Root | Original total | Champion total | Δ total | Δ B-line subtotal | Δ Meander subtotal | B-line 100-step worst-10% mean, original → champion | Meander 100-step worst-10% mean, original → champion |
| ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| 153 (selection and replay) | −57.2553 | **−56.7823** | +0.4730 | +0.5113 | −0.0383 | −24.381 → −22.997 | −25.023 → −24.740 |
| 42 | −57.4506 | **−56.8183** | +0.6323 | +0.0107 | +0.6216 | −23.953 → −23.242 | −27.224 → −23.818 |
| 2026 | −57.3200 | **−57.2406** | +0.0794 | +0.1609 | −0.0815 | −24.802 → −23.552 | −25.176 → −25.067 |

The B-line subtotal and 100-step worst-10% mean improved at all three roots. Meander supplied most of the gain at root 42. Its one 100-step return below −100 (−107.1) was absent from the champion run. Meander's worst return nevertheless declined from −62.7 to −75.0 at root 153 and from −39.6 to −69.7 at root 2026. The full root is the comparison unit under continuous resets. Later episode indices can refer to different sampled starts after a concrete action diverges.

Of 116 variants, 20 improved, 60 tied and 36 declined on root 153. The Enterprise0 runner-up `[6, 2, 0, 7]` scored **−56.7877**, with deltas of +0.3106 for B-line and +0.1570 for Meander. Four Defender orders tied at **−56.9897** (+0.2656), with distinct concrete-action trace hashes. Op_Server0 gained no points over its current ordering. User1 and User2 orders tied in total, although some changed executed Decoys. The User3 swap lost 0.2580.

The next proposed experiment freezes both Enterprise0 finalists and crosses them with the four tied Defender orders (eight root-153 full validations, 4,320,000 transitions). Comparing each combination with its two archived single-host treatments identifies non-additive score effects on this protocol. Any new champion can be checked against the current Enterprise0-only table on independent roots before an update to the default.

The run on Harry is under `/home/hagrid/bes-deploy/root153-allhost-decoys-20261123`. The verified WSL copy is `/home/hardison/bes-artifacts/runtime/root153-allhost-decoys-20261123/evidence`. It contains the 117-table leaderboard, frozen winner, evaluation manifests, finalist and replay episode returns, key logs, and a source manifest with SHA-256 digests and paths to the raw action traces on Harry.


## Frozen final schedule and integrated replay

The complete Controller and three-graph bundle is pinned by the Git tag release/cage2-root153-v1. Enterprise0 [6, 2, 0, 7] and Defender [7, 2, 0, 6] reached **-56.6674** on the official continuous-reset root 153 protocol, with zero episodes below -100. The bundle includes the original winning-record and official-results files. The batch compiler, optimizer and graph-analysis commands are linked from [README.md](README.md).

Materialize the release with scripts/bes-search materialize root153 NEW_DIRECTORY. Use scripts/bes-search validate BUNDLE OUTPUT for a new run. A separate archive tag, archive/meander-v15-compilation, provides the reference catalogue, original fallback and archived contexts for the compiler regression.

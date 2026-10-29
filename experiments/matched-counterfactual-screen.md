# Matched official counterfactual screen: frozen Level 2 protocol

This experiment compares structural and random action nominations on identical official Meander incumbent states. It does not train, modify the checkpoint, or synthesize a learner. The action pairs are generated mechanically from the committed Level-1 lanes, before any Level-2 reward is observed.

## Input identity

- Frozen gen-463 Meander parent, SHA256 de2b3f3b09b24cd6c011afe1f8247dacfd4fc55a0381a621529a40af521a0312.
- Level-1 nomination output at /home/hardison/bes-artifacts/validations/meander-structural-opportunity-level1-20261029/lanes.json.
- Five Level-1 state/path groups and their structural tie samples are immutable.
- If the Level-1 random action equals the structural action, resample random uniformly from the other listed feasible same-target candidates with independent RNG seed 271829. If no alternative exists, exclude that group from both lanes. The collision result is written to and committed as a manifest before official reward evaluation.
- The two lanes are never allowed to share a candidate action within a group.
- Do not use known User2 repair or teacher actions to choose or replace any nomination.

## Official opportunity and budget

- Fresh seed block: 12000000 + 197*i, i=0..99; disjoint from the Level-1 and prior specialist cohorts.
- Official environment: Cage2-meander-100-v0; 62 inputs, stateless TPG, fixed opening and the saved Meander Controller profile.
- For each seed run the unchanged incumbent baseline once. For each group in fixed manifest order, select the first nonopening step with its exact terminal team and host-observation tuple where both nominated actions are Controller-feasible and both resolve to concrete actions different from the incumbent. Do not choose a later more favorable event.
- Cap at 20 distinct seed episodes per group in seed order. No group may consume another group's branch budget. Stop after 100 scanned seeds even if a group has fewer than 20 matches.
- At that same state and exact concrete-action prefix, run one full episode with the structural action substituted once, then resume the frozen incumbent; separately run the random action substituted once and resume the same incumbent. The official replay must verify simulator/RNG/controller state and full prefix. The two branches share the same baseline state, not necessarily the same later random events.
- Each lane receives exactly one branch per accepted group/seed opportunity. Record actual transition counts for baseline and each lane; a mismatch in matched branch counts fails the run.

## Analysis frozen before outcomes

For each matched event record both branch-minus-baseline full-return changes and the direct structural-minus-random return difference. The primary comparison is the unweighted mean across groups of each group's mean structural-minus-random difference. Report each group separately. Estimate uncertainty by resampling independent seed IDs with replacement (2,000 bootstrap replicates, RNG seed 20261029), recomputing group means and their unweighted average. Also report each lane's mean branch-minus-baseline change, positive/negative/tie counts, branch transition budget, and worst losses. Units are episodes/seeds, never individual steps.

No claim of structural superiority follows from one random nomination draw or a confidence interval crossing zero. These five known-case groups are a calibration set; a later unseen checkpoint remains necessary for generality. Level 3 specialist synthesis is out of scope.
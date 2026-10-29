# New gap discovery screen: B-line v14

This is an independent calibration run of the target/path gap nomination and
four-response official counterfactual screen. The known Meander User2 repair
is not used by the selection algorithm. No genotype or incumbent checkpoint
will be modified.

- Input checkpoint: `validated-checkpoints/bline-v14/bline-62-36-v14.lisp`.
  Environment: `Cage2-b_line-100-v0`, 62-input stateless policy, fixed opening
  and B-line Controller Decoy order.
- Discovery rollouts: 100 seeds `14000000 + 197*i` for `i=0..99`.
- Use the unchanged Level-1 group and support score. Collapse response rows
  to their `(terminal team, target, four host bits)` group by taking the
  maximum eligible score. Require at least 40 independent episode exposures.
  Select the highest-score group for each of five distinct targets. No
  response type is selected from this score.
- For each selected target, choose a random control group from other eligible
  groups with the same target and closest discovery episode exposure. Break
  exposure ties uniformly with RNG seed 812731. This is a control for group
  selection, not a matched single-state action counterfactual.
- Response screen: for structural and random groups separately, 100 fresh
  official seeds `15000000 + 197*i`. The first 40 matching seed episodes per
  group are recorded, split into 20 discovery and 20 confirmation episodes.
  Each candidate response receives the same state opportunity within its
  group. Test all four Controller-feasible Semantic-36 responses through
  full-episode single-step intervention and incumbent continuation.
- Confirmed opportunity means the response selected on discovery by largest
  mean return is positive on confirmation, with at least 15 available
  episodes and at least 15 positive deltas. Report all responses and costs,
  not only winners. This threshold is a screening rule, not a policy
  promotion criterion.
- Do not synthesize a specialist or change training selection based on this
  run. If the automatic group selection or confirmation fails, report that
  outcome without tuning the score on these results.

## Prereward feasibility amendment

The frozen 100-episode B-line audit completed before any substitute-action
return was measured. It produced only five eligible groups with at least 40
episode exposures, across four targets. Every structural score was exactly
zero because the loss-lift factor vanished. Therefore the five-distinct-target
structural-versus-random comparison above is infeasible; it must **not** be
reported as a successful structural discovery experiment. Before running a
response intervention, the exploratory fallback was frozen: test all five
eligible groups, sorted by episode exposure and then target/bits, and report
the results as coverage-only hypothesis generation. No random control or
structural superiority claim applies to this fallback.

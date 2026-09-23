# Phase 4a Contract: Grouped Epsilon-Lexicase Survival

Phase 4a tests one hypothesis: aggregate scalar truncation may delete
behaviorally complementary partial solutions before TPG composition can use
them. The only major treatment change is survivor selection. Semantic-36,
Phase-3 v2 locality control, DAgger, controller state, official racing and
promotion, and reproduction-parent sampling remain unchanged.

## Cases and score

Each policy is still evaluated once per DAgger row with the existing score:

```text
0.8 * executable top-choice correctness + 0.2 * ranking NDCG
```

The same row scores are averaged into the existing aggregate fitness and into:

- four phase cases: steps 3-9, 10-29, 30-49, and 50-99;
- teacher `(target,response)` cases with at least five rows in that generation.

Rows from smaller teacher-pair groups still contribute to phase cases and the
aggregate score. No individual-row, critical-state, recovery, or red-agent
cases are used.

For each active case, epsilon is the raw median absolute deviation of case
scores across the full pre-selection evaluated root population. It is computed
once per generation. A zero MAD remains zero. The separate `1d-12` numerical
tolerance only protects floating comparisons and is not a statistical floor.

## Survivor selection

The intended survivor count remains:

```text
population roots - floor(gap * population roots)
```

The aggregate scalar champion is retained first. Every remaining slot starts
from all unselected evaluated roots, independently permutes the active cases
with a private deterministic RNG, filters by `best - frozen epsilon`, breaks a
remaining tie with that same RNG, and removes the winner from further slots.
Reproduction continues to sample approximately uniformly from the actual root
pool after ordinary `delete-team` reference updates. Internal teams that become
roots are recorded and remain eligible exactly as before.

The selection RNG is counter-based and independent of `*random-state*`. Its
root, cursor, and Phase-4 selection age are stored in checkpoint version 19 and
the official-guided runtime journal.

## Diagnostics only

A rescued specialist must be a discriminative case elite, beat the aggregate
champion on that case, fall strictly below the old scalar survivor cutoff, and
differ from the champion on that case's rows. Diagnostics record the old scalar
counterfactual and specialist lifecycle through generated, root-survived,
internalized/reachable, visited, and terminal-winning states. Terminal-winning
is observational, not causal.

Records are appended to the existing `behavioral-locality-records.lisp` journal
and never alter selection, mutation, or official promotion.

## Decision points

- Around generation 50: verify specialists are generated and retained and that
  survivor fingerprints do not immediately collapse to two or three behaviors.
- Around generations 100-250: inspect specialist lifetime, internalization,
  reachability, visits, and terminal wins.
- Around generation 500: inspect official challenger stages and promotions.
- Continue to generation 1000 only when the generated -> survived -> composed
  -> invoked chain is present but task-level benefit is still uncertain.

Phase 4a adds no novelty search, duplicate suppression, fingerprint cap, new
mutation, critic, labels, observation/action representation, recurrence, or
offline objective.

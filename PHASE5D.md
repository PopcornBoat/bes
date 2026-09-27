# Phase 5D: Counterfactual Step Credit

Phase 5D asks a narrower question than another guided-training run:

> At a recurring teacher/student disagreement, would changing this one action
> improve the official episode return while leaving the preceding trajectory
> unchanged?

## Frozen scope

- official CAGE2 is the transition and reward authority;
- 62-input stateless TPG;
- Semantic-36 target/response terminals;
- fixed opening and fixed controller Decoy order;
- the protected Phase 5C v17 checkpoint is not mutated;
- the heuristic teacher nominates an alternative action but does not assign
  return credit;
- no mutation, repair injection, selection, recurrent policy, or action-space
  change occurs in Phase 5D-1.

## Exact intervention protocol

For every requested seed:

1. Run the frozen checkpoint normally and locate the first occurrence of the
   requested `(teacher-pair, behavior-pair)` disagreement.
2. Reset the same official environment with the same seed.
3. Replay the exact concrete-action prefix. Every selected prefix action is
   checked against the baseline, and the controller is updated only from each
   action actually reported by the bridge.
4. Assert that the 62-value policy observation and both semantic proposals at
   the intervention step match the baseline.
5. Execute the teacher-nominated semantic pair once through the ordinary Lisp
   controller and bridge.
6. Return control to the unchanged frozen checkpoint for the rest of the
   episode.

The paired credit is:

```text
delta = intervention return-to-go - baseline return-to-go
```

Because rewards and actions before the intervention are verified identical,
this is also the difference in full episode return. Same-seed pairing starts
from the same RNG state; after the changed action, environment branches may
consume randomness differently, so this is not described as event-keyed RNG
coupling.

## Discovery and holdout

The request must contain disjoint, explicit `:discovery-seeds` and
`:holdout-seeds`. Seeds are never drawn from training, racing, promotion, or
reference streams. The runner reports event coverage, positive/zero/negative
counts, mean delta, sample standard deviation, standard error, and a normal
95% interval for each cohort.

Discovery determines whether the nominated correction is promising. Holdout
is the independent confirmation and must not be repurposed to tune the error
group.

## Request format

```lisp
(:protocol :phase5d-counterfactual-credit-request-v1
 :checkpoint "/absolute/path/to/protected-v17.lisp"
 :environment "Cage2-b_line-100-v0"
 :intervention-source :teacher
 :teacher-pair (5 3)
 :behavior-pair (2 0)
 :discovery-seeds (101 102 103)
 :holdout-seeds (201 202 203))
```

Run:

```bash
scripts/phase5d-credit REQUEST.sexp OUTPUT_DIRECTORY
```

The output contains the normalized request, complete paired trajectories,
compact paired results, summary statistics, and an input SHA-256 record.

## Gate to Phase 5D-2

Program-patch synthesis begins only if a recurring correction has useful
coverage and a positive paired return effect that survives the untouched
holdout block. Phase 5D-2 may then target the relevant learner program, but it
must still pass behavioral-locality, collateral-damage, grouped selection, and
official paired promotion gates. A teacher label by itself never authorizes a
genotype edit or historical-best replacement.

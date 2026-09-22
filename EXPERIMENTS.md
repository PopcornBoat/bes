# Official-Guided Experiments

## Completed Phase 1 baseline

The first controlled run stopped cleanly at generation 387. It retained the
imported official incumbent at `-50.808`; 35 of 35 staged challengers were
rejected. Ranked-imitation challengers reached roughly `0.65`, but their paired
official means remained far below the incumbent. Near the end, proposal
disagreement was about 98%, first disagreement was near step 3-4, and the
teacher action was absent from the TPG top-8 on more than half of policy rows.

This establishes that the Phase 1 racing gate protects the incumbent, while
ranked imitation does not yet produce reliable local official improvement.

## Phase 2 run

The first instrumentation run stopped cleanly at generation 722 with 721
mutation generations and 71 official challenger outcomes. It found strong
non-locality (about 22.6% of children changed top-1 behavior on at least half
of the archive; about 11.8% changed every probe), plus substantial graph bloat.
No challenger replaced the `-50.808` incumbent.

That run also exposed two attribution defects and must not be used for causal
return-versus-mutation conclusions. DAgger was controlled by `*BEST-TEAM*`, so
zero promotions kept the state distribution anchored to the imported
incumbent. In addition, official return compared candidate with incumbent while
the attached distance compared child with its direct parent.

The corrected protocol now:

```text
previous generation imitation champion (deep copy)
  -> next generation mixed DAgger rollout

candidate vs incumbent
  -> promotion only

child vs exact direct parent on the same racing seeds
  -> mutation-locality evidence only
```

The DAgger snapshot is journaled independently. Warm-start initialization does
not overwrite an existing best checkpoint; only accepted Stage-3 promotion can
replace it.

Use the same menu configuration and warm-start checkpoint described below on
the `behavioral-locality` branch. Use a new checkpoint directory. Phase 2
automatically writes `behavioral-locality-records.lisp`; there is no new menu
switch because this branch is the controlled measurement condition.

Run until the journal contains enough examples in each mutation-event group and
at least 30-50 official challenger outcomes. Do not stop because historical best
does not improve: the primary product is the disruption/return dataset.

After the run, group records by mutation event and behavioral-radius bins, then
report:

```text
mean paired official delta
P(paired delta < -100)
top-1 Hamming
ranking distance
teacher-rank change
top-8 overlap
teacher-off-support rate
```

The action-space mask remains a later controlled ablation (`full-41` versus
teacher-supported-36), not part of this measurement run.

## Required configuration

Use the Emacs menu and select:

```text
mode: official-guided
environment: Cage2-b_line-100-v0
observations: 62
actions: 11
memory: stateless
opening: fixed
decoy order: fixed
teacher rollout: dagger
teacher backend: model
hamming: disabled
fitness episodes: 5
```

The recommended first controlled run warm-starts from:

```text
/home/hardison/checkpoints/mix/bline-62/mix-platform-50.808-full-validation-input.lisp
```

Use a new checkpoint directory. Do not overwrite the source checkpoint.

## Runtime evidence

The log must show, per DAgger generation:

```text
disagreement rate
mean first-disagreement step
teacher action absent from student top-8
teacher mixing rate
teacher-controlled steps
learner-controlled steps
mixed rollout return
```

Every tenth generation, the best ranked-imitation challenger is submitted to an
independent official worker. The worker first runs five paired racing episodes.
If not futile it receives a fresh promotion block with cumulative checks at 12,
40, and 100 paired episodes. A successful challenger is additionally measured
on monitoring seeds derived from roots 153, 42, and 2026; those results never
change the promotion decision.

## Comparison

Run equal-wall-clock comparisons from the same source checkpoint:

- existing pure official online fine-tuning;
- official-guided Phase 1.

Report official full validation separately. Do not compare mixed-rollout return
or ranked-imitation fitness directly with official validation reward.

## Phase boundary

Do not tune mutation rates in response to this experiment. Do not add recurrent
registers, lexicase, behavioral-distance constraints, soft logits, or digital
twin fitness on this branch.

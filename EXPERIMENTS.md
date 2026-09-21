# Phase 1 Experiments

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

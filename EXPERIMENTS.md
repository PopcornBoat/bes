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

The direct Semantic-36 action contract remains fixed across the Phase-2/3
comparison; action-space ablations are outside these runs.

The corrected passive-sampling run stopped at generation 1116 with 1112 paired
official parent/child outcomes distributed almost evenly across all five
distance strata. Its key result was monotonic catastrophic risk: the probability
of a return drop greater than 100 rose from `0.087` for probe-neutral mutations,
to `0.379` for small Top-1 changes, `0.556` for medium changes, and `0.935` for
changes above 50%. Learner-action swaps were the clearest high-risk associated
event (`0.819` probability of a drop greater than 100). This is the evidence
used to enter Phase 3; overlapping event groups are not interpreted causally.

## Phase 3 run

Run the `semantic-locality-control` branch from the protected Phase-2 incumbent:

```text
/home/hardison/checkpoints/semantic36/phase2-locality-sampling/
bline-62-36-official-guided-dagger-order-fixed-teacher-heuristic-opening-fixed-hamming-off-memory-stateless.lisp
```

Use a new directory, recommended:

```text
/home/hardison/checkpoints/semantic36/phase3-locality-control/
```

The treatment is defined in `PHASE3.md`. During the first 250 control
generations the expected tier mix is 60% local, 25% bounded, and 15% unrestricted
exploration. Stop early and diagnose if fallback is close to every controlled
child, unrestricted exploration stays at zero over a meaningful window, or
offspring generation dominates wall-clock time. Otherwise collect at least
250 generations before comparing the Phase-3 transition schedule with Phase 2.

The v1 treatment stopped cleanly at generation 596.  It confirmed that large
behavioral changes are dangerous, but the transition stage saturated: over the
last 100 generations 83.8% of children exhausted retries and 87.9% were
probe-neutral.  Fifty-six official outcomes produced no Stage-3 promotion.

Phase-3 v2 starts from the exported generation-595 DAgger behavior policy, not
the older protected Phase-2 incumbent:

```text
/home/hardison/checkpoints/semantic36/phase3-locality-control-v2-source/
bline-62-36-official-guided-locality-control-order-fixed-teacher-heuristic-opening-fixed-hamming-off-memory-stateless.lisp
```

Its journal continues the generation-595 seed cursors, probe archive, DAgger
behavior state, and control age.  The imported policy becomes the explicit v2
incumbent; the old incumbent's official score is not assigned to it.

Use a separate output directory:

```text
/home/hardison/checkpoints/semantic36/phase3-locality-control-v2/
```

In addition to the existing official outcomes, monitor:

```text
fallback and escalation rates
effective local/bounded/explore/neutral counts
unique Top-1 and ranking fingerprints
mean pairwise Top-1 Hamming and action entropy
teacher Top-8 mean and population-union coverage
dominant target/response pair and rate
DAgger disagreement by episode phase
teacher -> TPG confusion counts
```

## Required configuration

Use the Emacs menu and select:

```text
mode: official-guided
environment: Cage2-b_line-100-v0
observations: 62
actions: 36
memory: stateless
opening: fixed
decoy order: fixed
teacher rollout: dagger
teacher backend: heuristic
hamming: disabled
fitness episodes: 5
```

## Phase 4a grouped epsilon-lexicase run

Use branch `grouped-lexicase-selection` and warm-start from the stopped Phase-3
v2 protected incumbent:

```text
/home/hardison/checkpoints/semantic36/phase3-locality-control-v2/
bline-62-36-official-guided-locality-control-order-fixed-teacher-heuristic-opening-fixed-hamming-off-memory-stateless.lisp
```

Keep the required configuration above and choose a new output directory, for
example:

```text
/home/hardison/checkpoints/semantic36/phase4a-grouped-lexicase/
```

The source checkpoint and its matching journal preserve incumbent version 14,
official best, DAgger behavior state, Phase-3 control age, probe archive, and
the four official seed streams. Warm start still creates a fresh population;
it is not a bit-for-bit continuation of the stopped population. Phase-4a's new
selection stream starts deterministically from the search seed and is then
checkpointed independently. The run-local filename contains
`official-guided-grouped-lexicase`, so it cannot overwrite the Phase-3 source.
When the output directory is new, resume automatically falls back to the
matching `.official-guided-state.lisp` beside the source checkpoint and then
writes subsequent state into the new output directory.

Before starting, run the focused and regression checks:

```bash
cd /home/hardison/bes
CL_SOURCE_REGISTRY='(:source-registry (:tree "/home/hardison/bes/") :ignore-inherited-configuration)' \
sbcl --non-interactive \
  --eval '(require :asdf)' \
  --eval '(asdf:load-system :cl-tpg :force t)' \
  --load tests/phase4-selection.lisp \
  --load tests/official-guided.lisp \
  --load tests/behavioral-locality.lisp \
  --load tests/semantic-offline.lisp
```

Do not automatically run to a fixed generation. Apply the decision points in
`PHASE4.md`, beginning with the generation-50 collapse/specialist audit.

### Completed Phase 4a and scalar-control comparison

The first controlled Phase-4a run stopped cleanly at generation 1003. It
started from the Phase-3 v2 protected incumbent (`-35.479`) and completed 64
official challenger evaluations. Two challengers passed the full 100-episode
Stage-3 promotion gate:

```text
generation 142: -29.892, paired delta +6.62 +/- 1.25
generation 599: -25.871, paired delta +3.06 +/- 0.70
```

The scalar-selection control used commit `5814914`, the same Phase-3 source
checkpoint and runtime journal, and the same search parameters. It stopped at
generation 1027 after 102 official evaluations. Its only promotion occurred at
generation 43 and reached `-31.379` (paired delta `+2.66 +/- 0.56`).

Deterministic `SINGLE-RED-FULL` validation used the same seed-153 sequence for
all checkpoints:

| Checkpoint | 30-step | 50-step | 100-step | Total |
|---|---:|---:|---:|---:|
| Phase-3 source | -8.1276 | -15.6395 | -35.5271 | -59.2942 |
| Scalar continuation | -7.5386 | -14.5565 | -32.9411 | -55.0362 |
| Grouped epsilon-lexicase | **-7.0124** | **-12.3831** | **-26.8397** | **-46.2352** |

The final 100 generations also show sharply different population behavior:

| Diagnostic mean | Scalar | Grouped epsilon-lexicase |
|---|---:|---:|
| Unique Top-1 fingerprints | 2.19 | 33.96 |
| Unique ranking fingerprints | 2.22 | 38.12 |
| Pairwise Top-1 Hamming | 0.0036 | 0.5154 |
| Normalized Top-1 entropy | 0.0020 | 0.2383 |
| Teacher Top-8 mean coverage | 0.5574 | 0.7020 |
| Teacher Top-8 population coverage | 0.5633 | 0.9997 |
| Dominant Top-1 pair rate | 0.7228 | 0.3046 |

The scalar population therefore converged to approximately two behavioral
fingerprints, whereas grouped epsilon-lexicase retained broad complementary
behavior and complete population-level teacher support. Together with the two
fresh-seed promotions and full-validation improvement, this run supports the
Phase-4a specialist-preservation hypothesis. It remains one controlled run;
independent search-root replications are required before treating the effect
size as a population-level estimate.

## Phase 4b-0 passive disagreement audit

Use branch `specialist-composition` and warm-start from the protected Phase-4a
incumbent and its matching runtime journal:

```text
/home/hardison/backup/official-guided/phase4a-grouped-lexicase-gen1003/
bline-62-36-official-guided-grouped-lexicase-order-fixed-teacher-heuristic-opening-fixed-hamming-off-memory-stateless.lisp
```

Write the audit continuation to a new directory:

```text
/home/hardison/checkpoints/semantic36/phase4b0-disagreement-audit/
```

Keep every Phase-4a setting unchanged. Phase 4b-0 only attaches
`:PHASE4B-REPAIR-AUDIT` to each existing DAgger disagreement journal record.
The one-line log reports Case A (teacher pair in Top-8), Case B1 (below Top-8
but backed by a reachable matching terminal), Case B2 (missing from the
behavior graph), and repeated cross-episode systematic issues. It does not
change mutation, selection, fitness, execution, or promotion.

Run at least 50 generations before interpreting the case distribution. Around
generation 50, inspect totals by case, episode phase, teacher pair, and teacher
rank. Stop the passive audit by generation 100 unless the distribution is too
sparse to identify whether 4b-A routing repair or 4b-B composition should be
implemented first. Do not use any checkpoint produced by this diagnostic run
as the source for the controlled 4b-A or 4b-B treatment; both treatments start
from the same protected Phase-4a source above.

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

## Phase 4b audit result and routing-repair pilot

The passive audit stopped cleanly after generation 326 (state advanced to
327). Across all windows it reported 0 Case-B2 missing-support disagreements.
Case A remained about 36--38% and Case B1 about 62--64%; rank 7/8 errors
dominated Case A. The first treatment is therefore routing repair over both
supported cases, not terminal or graph injection.

Use branch `specialist-composition` and the same protected source used by the
audit, not an audit-run checkpoint:

```text
/home/hardison/backup/official-guided/phase4a-grouped-lexicase-gen1003/
bline-62-36-official-guided-grouped-lexicase-order-fixed-teacher-heuristic-opening-fixed-hamming-off-memory-stateless.lisp
```

Write to a new directory such as:

```text
/home/hardison/checkpoints/semantic36/phase4b-a-routing-repair/
```

Keep all Phase-4a parameters unchanged. Expected per-generation evidence is:

```text
Phase-4b-A routing repair: slots=N accepted=A fallback=N-A
```

The detailed locality journal must show accepted records with target-group
Top-1/rank gains, no collateral exact losses, collateral rank-regression rate
at most 0.05, and Top-1/ranking distances at most 0.20.

Use these early stop rules:

- stop immediately on a crash, checkpoint/state resume mismatch, population
  deficit, or mutation of a shared/internal team;
- after 50 generations, stop and fix the operator if targeted slots occur but
  none are accepted;
- after 100 generations, stop if acceptance is below roughly 1% and no
  systematic issue's target rank improves;
- otherwise run 300--500 generations for the first decision, while retaining
  only Stage-3 official promotions as historical best;
- a promising outcome is repeated accepted local repairs, stable collateral,
  improved DAgger first-disagreement/ranking metrics, and at least one
  fresh-seed official promotion over `-25.871`.

Full validation remains a separate final report. Mixed return and imitation
fitness are diagnostic and must not replace official promotion evidence.

A nine-generation runtime smoke test from the protected source completed
without a crash or population deficit. Targeted scheduling produced 4--14
slots per generation. Three repairs were accepted: one Case-B1 repair moved
the teacher pair from outside Top-8 to Top-1, while a Case-A repair improved
teacher rank from 7 to 4. Every accepted repair had zero collateral exact
losses, zero collateral rank regressions, and both locality distances below
0.20. This establishes operability only; it is not a performance result.

### Completed Phase 4b-A pilot

The controlled Phase-4b-A run stopped after generation 508. Repair acceptance
fell from about 2.0% in the first 100 generations to about 0.7% in generations
401--500. Accepted repairs remained within the locality and collateral gates,
but none of 50 official challenger outcomes promoted over the protected
Phase-4a incumbent; four reached Stage 3 and were rejected. DAgger disagreement
and first-disagreement time remained near 45% and step 3.5 respectively.

The absent-from-Top-8 rate improved from about 64.6% to 58.9%, while the live
population retained roughly 30--33 unique Top-1 fingerprints, pairwise Top-1
Hamming of 0.54--0.61, and approximately 95% population-level teacher Top-8
coverage. This supports testing composition of complementary live specialists,
not continuing single-bidder repair indefinitely.

## Phase 4b-B specialist-composition pilot

Use branch `specialist-composition`. Start from the same protected Phase-4a
checkpoint used by Phase 4b-A:

```text
/home/hardison/backup/official-guided/phase4a-grouped-lexicase-gen1003/
bline-62-36-official-guided-grouped-lexicase-order-fixed-teacher-heuristic-opening-fixed-hamming-off-memory-stateless.lisp
```

Do not start from a Phase-4b-A checkpoint. Write to a separate directory:

```text
/home/hardison/checkpoints/semantic36/phase4b-b-specialist-composition/
```

Keep all Phase-4a parameters unchanged. The log should report:

```text
Phase-4b-B specialist composition: slots=N accepted=A fallback=N-A
```

The detailed journal record is
`:PHASE4B-SPECIALIST-COMPOSITION-GENERATION`. Inspect the selected issue group,
donor and gateway learner, source type, target improvement, collateral losses,
and locality distances. `:TEAM-REFERENCE` is the intended composition path;
`:DIRECT-TERMINAL-FALLBACK` means no current live donor qualified.

Apply these decision points:

- stop immediately on a crash, checkpoint/runtime-state mismatch, population
  deficit, cycle, or donor reference-count/root-status leak;
- at generation 50, require scheduled attempts and at least one safe accepted
  composition or clearly logged direct-terminal fallback;
- at generation 100, stop and revise if acceptance is below about 1%, no
  team-reference composition is accepted, and absent-from-Top-8 or
  first-disagreement diagnostics do not improve;
- otherwise continue 300--500 generations for the first controlled decision;
- promising evidence is repeated safe team-reference composition, declining
  Case-B1/absent-Top8 errors, later first disagreement, stable diversity, and
  at least one Stage-3 official promotion over `-25.871`.

Full validation is run only after the controlled decision point. Mixed return
and imitation fitness remain diagnostics and cannot promote the historical
incumbent.

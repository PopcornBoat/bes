# Phase 2 Contract: Measure Semantic Disruption

Phase 2 answers one question:

> How much semantic policy change does each existing mutation produce, and how
> does that change relate to paired official return?

It does not attempt to make mutation more local. Selection, mutation
probabilities, mutation operators, DAgger, ranked imitation, official racing,
and historical promotion remain the Phase 1 implementation.

## Invariants

- Instrumentation consumes no search RNG and makes no selection decision.
- Every reproduced child is compared directly with its actual parent.
- The comparison uses the same probe archive for every child in one generation.
- Probe archive revision and protocol version are stored with every record.
- The archive is at most 64 unique observations:
  - 16 long-lived teacher/reference states;
  - 16 long-lived early-critical states after the fixed opening;
  - 16 deterministic states spanning the current trace;
  - 16 current disagreement or teacher-absent states.
- The fixed half is retained across generations. The rolling half is refreshed
  after each DAgger trace. Archive state is checkpointed and journaled.
- Official candidate records retain the submitted winner's independently
  frozen direct parent. Child and parent are evaluated on the same racing seed
  block, producing a causal parent-to-child paired-return record. The separate
  candidate-versus-incumbent comparison continues to control promotion.
- The current direct Semantic-36 terminal protocol remains unchanged. Fixed
  controller-side Decoy expansion is outside the evolved policy. Phase
  2 measures teacher-off-support output but does not mask it.

## Behavioral measurements

For probe states `s_1 ... s_N`, parent `p`, and child `c`:

```text
top1_hamming = (1/N) * sum I[top1_p(s_i) != top1_c(s_i)]
```

Teacher rank is the zero-based rank of the demonstrated executable semantic
pair in the TPG top-8. Absence is encoded as rank 8. Records contain both the
fraction of probes whose teacher rank changed and mean absolute rank change.

Top-k overlap is:

```text
overlap = |top8_p(s_i) intersect top8_c(s_i)| / 8
```

Ranking similarity is symmetric NDCG:

```text
sim(p,c) = 0.5 * (NDCG(c | p) + NDCG(p | c))
ranking_distance = 1 - mean(sim(p,c))
```

For a reference ranking of length `m`, relevance at reference rank `j` is
`m-j`, and:

```text
DCG = sum_j relevance(prediction_j) / log2(j + 2)
NDCG = DCG / ideal_DCG
```

The record additionally contains parent/child top-1 action distributions,
teacher-off-support rates, reachable graph complexity, and applied mutation
events.

## Mutation event layers

The passive trace distinguishes:

```text
instruction add/delete/swap
constant mutation
program mutation
learner add/delete
learner action swap
terminal target mutation
terminal response mutation
team-edge mutation
decoy-order mutation (inactive in the fixed-order baseline)
```

Multiple events may be attached to one child because the existing mutation
pipeline may apply multiple operators.

## Output

Each checkpoint directory receives:

```text
behavioral-locality-records.lisp
```

It contains one readable `:MUTATION-GENERATION` form per generation and one
`:OFFICIAL-OUTCOME` form per completed staged challenger. The latter contains
two deliberately separate comparisons: candidate versus protected incumbent
for promotion, and child versus its exact direct parent for mutation-locality
analysis. Both retain exact seeds, paired uncertainty, and the behavioral
diagnostic.

The immediate runtime summary reports mean top-1 Hamming, teacher-rank change,
ranking distance, top-8 overlap, and child off-support rate.

## Offline analysis

The append-only journal can be summarized without loading a checkpoint or
changing search state:

```bash
sbcl --load ~/quicklisp/setup.lisp --script scripts/analyze-behavioral-locality.lisp \
  /path/to/behavioral-locality-records.lisp \
  /path/to/behavioral-locality-report.md
```

The report groups semantic disruption by mutation event, links official
parent-to-child paired return to distance bins, and reports catastrophic-drop
probabilities at 10, 25, 50, and 100 reward. Event groups overlap for children
with multiple mutation events and are therefore associations, not isolated
operator effects.

## Phase boundary

Do not use these values to reject mutation, change operator probabilities,
change action support, or select survivors in Phase 2. Those are Phase 3
experiments after the disruption/return relationship is measured.

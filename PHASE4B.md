# Phase 4b: Error-Directed Variation

Phase 4b starts from the protected Phase-4a grouped epsilon-lexicase
checkpoint. It does not retrain Phases 1--4a from scratch.

## Frozen controls

The following remain unchanged: 62-input stateless TPG, direct
target-response-36 terminals, fixed opening, fixed controller-owned Decoy
order, Lisp heuristic teacher, mixed DAgger, Phase-3 locality control,
grouped epsilon-lexicase survival, official paired racing, fresh 12/40/100
promotion, and deep-copied historical best checkpoints.

## Phase 4b-0: passive disagreement audit

Phase 4b-0 changes no mutation, selection, execution, or promotion decision.
For every DAgger Top-1 disagreement it records:

- `CASE-A-ROUTING`: the teacher target/response is already in the current
  Top-8 but loses the bid/routing order;
- `CASE-B1-REACHABLE-SUPPORT`: the teacher pair is absent from Top-8 but a
  matching direct terminal exists in the behavior graph's reachable closure;
- `CASE-B2-MISSING-SUPPORT`: the teacher pair is absent from Top-8 and no
  matching terminal exists in that closure.

B1 is deliberately genotype support, not proof of a reusable specialist. A
later composition operator must additionally use group performance and
specialist lifecycle evidence before linking another team.

An issue is called systematic only when the same case, phase, teacher pair,
predicted pair, and teacher rank occurs at least three times across at least
two distinct episode seeds. The complete counts remain recorded even when
that threshold is not reached.

The audit is appended to the existing `DAGGER-DISAGREEMENT-GENERATION` journal
record through `:PHASE4B-REPAIR-AUDIT`. It consumes no random numbers and does
not create offspring.

The protected audit ran for 326 complete generations. Its distribution was
stable across windows: approximately 36--38% Case A, 62--64% Case B1, and zero
Case B2. Rank 7 and rank 8 dominated Case A. This is evidence of a
routing/ranking bottleneck with existing genotype support, not missing action
vocabulary, so terminal injection is not part of the first treatment.

## Phase 4b-A: targeted routing repair

Ten percent of offspring slots are independently scheduled for an attempted
repair. The schedule has its own counter-based, checkpointed RNG stream and
does not consume Phase-4a selection draws. A systematic Case-A or Case-B1 issue
is sampled by occurrence count. Only roots whose reachable graph contains the
teacher pair are eligible.

For one eligible root, current-generation rows must reproduce the same phase,
teacher pair, predicted Top-1 pair, and Case-A/B1 rank condition. At least
three matching rows are required. The root is cloned and exactly one cloned
root learner whose direct action or referenced subtree supports the teacher
pair is selected. Only that learner's bid program is passed to the ordinary
native `mutate-program` operator. Terminal payloads, actions, graph edges, and
shared internal teams are not edited by a targeted attempt.

Up to eight program variants are tried. A child is admitted only when:

- it gains a teacher Top-1 decision or improves mean teacher rank on the
  selected group, with no Top-1 loss in that group;
- it loses no previously correct teacher Top-1 decision outside the group;
- at most 5% of non-target probe states suffer teacher-rank regression; and
- archive Top-1 Hamming and ranking distance are both at most 20%.

A failed targeted slot falls back to the unchanged Phase-3/native reproduction
path. An accepted child is only an ordinary population member: grouped
epsilon-lexicase, official paired racing, fresh 12/40/100 promotion, and the
deep-copied historical incumbent remain authoritative. The incumbent is never
edited directly.

Every slot decision is journaled as
`:PHASE4B-ROUTING-REPAIR-GENERATION`, including the issue, selected learner,
target-group change, collateral damage, and locality distances. The scheduling
root/cursor/age are stored in checkpoint version 20 and runtime-journal version
5. Phase-4b-A uses a distinct `official-guided-routing-repair` filename.

## Deferred Phase 4b-B

Case B would first attempt to reuse a group-qualified live specialist through
a cycle-safe team reference. Only when no qualified specialist exists may it
create a learner with the missing target-response terminal. This is deferred
because the audit observed no Case-B2 missing-support event.

## Attribution rule

4b-A and 4b-B must first be piloted separately from the same protected Phase-4a
checkpoint. Only after their effects are measured may a combined run choose
the repair operator from the observed disagreement case. Ordinary mutation
remains the majority path throughout Phase 4b.

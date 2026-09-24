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

## Planned Phase 4b-A

Case A will generate a small minority of targeted offspring by choosing the
existing path that expresses the teacher pair and applying ordinary native
program mutation to its bid/routing program. Targeted offspring must improve
the error group, pass the existing locality and collateral-damage gates, and
then compete under unchanged grouped epsilon-lexicase and official promotion.
The incumbent is never edited directly.

## Planned Phase 4b-B

Case B will first attempt to reuse a group-qualified live specialist through a
cycle-safe team reference. Only when no qualified specialist exists may it
create a learner with the missing target-response terminal. Its bid program
still evolves through native TPG mutation.

## Attribution rule

4b-A and 4b-B must first be piloted separately from the same protected Phase-4a
checkpoint. Only after their effects are measured may a combined run choose
the repair operator from the observed disagreement case. Ordinary mutation
remains the majority path throughout Phase 4b.

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

## Phase 4b-A result

The controlled Phase-4b-A run stopped after generation 508. Targeted repair
acceptance declined from about 2.0% in generations 1--100 to about 0.7% in
generations 401--500. Accepted repairs remained local and caused no measured
collateral Top-1 loss, but no challenger passed Stage-3 promotion over the
protected Phase-4a incumbent. DAgger disagreement stayed near 45% and the mean
first-disagreement step stayed near 3.5. Teacher-pair absence from Top-8 fell
modestly, from about 64.6% to 58.9%.

The population itself remained diverse: roughly 30--33 unique Top-1
fingerprints, pairwise Top-1 Hamming around 0.54--0.61, population teacher
Top-8 coverage around 95%, and individual mean coverage around 65%. This is
the Phase-4b-B motivation: useful support is distributed across roots, but
mutating one existing bidder at a time did not reliably integrate it into a
better policy.

## Phase 4b-B: specialist composition

Phase 4b-B is an isolated treatment. Phase 4b-A routing repair is disabled,
and the run starts from the same protected Phase-4a checkpoint rather than a
Phase-4b-A descendant. Ten percent of offspring slots are scheduled by a
separate counter-based RNG stream whose root, cursor, and age are checkpointed.

Only systematic Case-B1 disagreements are eligible. The operator identifies
the most specific available error group (teacher target/response, otherwise
episode phase), scores current live roots on that group, and searches up to
eight group-elite donors. A donor qualifies only if it ranks the teacher pair
Top-1 on at least one exact issue context. Its most frequently winning root
learner becomes the gateway specialist.

The preferred candidate adds one new learner to a clone of the selected
parent. That learner keeps the donor gateway bid program and points through a
cycle-safe team reference to the donor root. Reference counts are updated with
the ordinary TPG lifecycle functions. If no live group-qualified donor exists,
the logged fallback adds a direct target-response terminal using a cloned
parent gateway program. The first attempt preserves the gateway program;
later attempts use the existing native `mutate-program` operator. No donor or
incumbent object is edited in place.

Up to eight variants are admitted through the same target-group improvement,
collateral-damage, and behavioral-locality gates as Phase 4b-A. Rejected
candidate graphs are deleted through the normal team lifecycle so donor
reference counts and root status are restored. Accepted candidates are only
ordinary offspring and receive no survival or promotion privilege.

Every slot is journaled as
`:PHASE4B-SPECIALIST-COMPOSITION-GENERATION`, including issue group, donor,
gateway learner, source (`:TEAM-REFERENCE` or `:DIRECT-TERMINAL-FALLBACK`),
target-group change, collateral damage, and locality distances. Checkpoint
version 21 and runtime-journal version 6 preserve the new RNG stream and
records. Phase 4b-B uses a distinct
`official-guided-specialist-composition` filename.

## Attribution rule

4b-A and 4b-B must be piloted separately from the same protected Phase-4a
checkpoint. Only after their effects are measured may a combined run choose
the repair operator from the observed disagreement case. Ordinary mutation
remains the majority path throughout Phase 4b.

## Phase 4b-B result

The isolated composition run stopped cleanly at generation 640. The controlled
analysis through generation 626 contained 5,022 scheduled attempts and 210
safe accepted children: 204 live team references and six direct-terminal
fallbacks. Accepted children produced 1,603 target-group Top-1 gains, zero
target-group Top-1 losses, and zero collateral exact losses. Population
diversity remained healthy, but the repair rate fell from 7.97% in generations
1--200 to roughly 2% late in the run.

Trajectory diagnostics improved transiently in generations 401--500, then
regressed. Across 62 official outcomes, five challengers reached Stage 3 and
none promoted over the protected `-25.871` Phase-4a incumbent. The closest
100-episode result was a paired delta of `-3.153 +/- 1.479`. Phase 4b-B
therefore demonstrated safe specialist integration, but not reliable official
return improvement.

## Phase 4b-C: case-directed combined repair

Phase 4b-C starts again from the protected Phase-4a checkpoint. It does not
inherit a Phase-4b-A or Phase-4b-B descendant. It changes no operator gate:

- one shared ten-percent quota selects a systematic issue by occurrence count;
- Case A dispatches to the tested Phase-4b-A routing repair;
- Case B1 dispatches to the tested Phase-4b-B specialist composition;
- Case B2 remains deferred;
- a failed repair slot falls back to unchanged native/Phase-3 reproduction.

The quota is ten percent total, not ten percent per operator. Its schedule and
issue choice use the checkpointed routing-repair stream. Composition retains
its independent checkpointed donor/parent stream. Both detailed operator
records and a combined dispatch record are journaled. Grouped epsilon-lexicase,
official racing, fresh-seed 12/40/100 promotion, and historical deep-copy
semantics remain authoritative.

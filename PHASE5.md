# Phase 5: Paired Official Return Credit

Phase 5A asks whether TPG can accumulate small environment-level improvements
when official return is used before the global historical-promotion boundary.
It is an isolated treatment from the protected Phase-4a checkpoint.

## Frozen controls

- 62-input stateless policy;
- direct Semantic-36 target/response terminals;
- fixed opening and controller-owned fixed Decoy order;
- side-effect-free Lisp heuristic teacher and mixed DAgger;
- existing ranked semantic imitation objective;
- Phase-3 semantic-local mutation control;
- Phase-4a grouped epsilon-lexicase;
- existing global racing and fresh 12/40/100 promotion;
- serialize/deserialize historical-best deep copies.

All Phase-4b routing, specialist-composition, and combined repair operators are
disabled. Phase 5A does not change mutation probabilities or add a targeted
mutation operator.

## Candidate and parent

Every ten generations, the submission window retains the strongest ranked-
imitation root that has a recorded direct mutation parent. Candidate, direct
parent, and global incumbent are independently serialized before an external
worker starts. DAgger behavior and dashboard fitness continue to use the
ordinary aggregate generation champion.

## Local official credit

Candidate and direct parent receive the same initial official CAGE2 seeds from
a dedicated, checkpointed `credit` stream. This common-random-number comparison
does not claim that later RNG events remain coupled after policies diverge.

The sequential protocol is frozen:

1. five paired episodes may reject a clearly futile child;
2. if still plausible, continue to 20 cumulative paired episodes;
3. approve only when mean child-minus-parent return exceeds one paired standard
   error.

An approved child is loaded as an independent root after the current generation
was evaluated. It crosses that deletion boundary once, then competes normally
under grouped epsilon-lexicase from the following generation. It is not assigned
historical-best status, does not overwrite the incumbent checkpoint, and gets
no permanent survival privilege.

Global candidate-versus-incumbent racing and fresh promotion remain separate.
Only an accepted Stage-3 result over 100 fresh paired episodes can replace the
historical incumbent.

## Seed and resume invariants

Training, racing, promotion, reference monitoring, passive locality sampling,
and return credit use distinct deterministic namespaces. The credit cursor and
approved/rejected counters are saved in checkpoint/runtime state. Legacy
four-stream official-guided checkpoints are upgraded by adding a fresh credit
stream without moving any existing cursor.

## Evidence and stop criteria

The journal records every credit decision with exact seeds, returns, paired
mean, paired SE, margin, locality record, and installed anchor ID. During the
first 100 generations verify:

- credit workers complete without blocking the main search;
- both Stage-1 rejection and Stage-2 decisions appear;
- approved anchors do not change the historical checkpoint directly;
- root population size remains stable after anchor insertion;
- Phase-4b repair records are absent.

At 300--500 generations, compare against the protected `-25.871` Phase-4a
incumbent. A promising outcome requires repeated positive parent-child credit,
retention or descendants of approved anchors, positive global paired
challengers, and ideally a fresh Stage-3 promotion. If local approvals occur but
all global deltas remain negative, the credit rule is accumulating local drift
rather than useful progress and must be revised before adding Phase-4b proposals.

## Completed Phase 5A result

Phase 5A stopped cleanly at generation 302. Of 29 direct parent/child credit
comparisons, three were approved and 26 rejected. Eighteen comparisons (62.1%)
had exactly zero official paired delta, and 16 (55.2%) had no Top-1 or ranking
change on the probe archive. All 29 global challengers were rejected; the
protected `-25.871` incumbent was never overwritten. Population diversity
recovered late in the run, so collapse was not the primary failure. The result
isolates two problems: imitation-only submission spends most official budget on
behaviorally inactive children, and a one-boundary anchor cannot accumulate a
sequence of local official improvements.

## Phase 5B: behavior admission and bounded lineage credit

Phase 5B is an isolated treatment from the same protected Phase-4a checkpoint.
It retains every Phase-5A control and changes only candidate admission and the
retention of an approved child.

Each generation classifies direct mutation children in this order:

1. behavior-changing child descended from an active credit lineage;
2. another behavior-changing direct child;
3. probe-neutral child descended from an active credit lineage;
4. another probe-neutral direct child.

The strongest ranked-imitation child within the highest available class enters
the ten-generation staging window. Classes 3 and 4 preserve a fallback for
changes outside the finite probe archive; they cannot displace an observed
behavior-changing child merely through higher imitation fitness.

The paired 5-then-20 credit test is unchanged. An approved child establishes or
advances a lineage with these frozen limits:

- at most three active lineages;
- one protected anchor per lineage;
- 12 evaluated survivor-selection cycles per approval;
- descendants inherit the lineage ID but receive no automatic protection;
- a later approved descendant replaces the protected anchor and refreshes the
  12-cycle budget;
- expired or evicted anchors remain ordinary roots and compete normally.

Forced survival consumes an ordinary grouped-lexicase survivor slot. It does
not enlarge the survivor population, change group scores, alter mutation, or
grant historical-best status. Candidate, direct parent, incumbent, credit seed
stream, and fresh global promotion remain independently serialized exactly as
before.

The runtime journal persists lineage IDs, anchor checkpoint paths, remaining
selection budgets, approval depth, and all seed cursors. Resume reloads active
anchors through the same deep serializer rather than reconstructing or sharing
their graphs.

### Phase 5B decision points

At generation 50 verify candidate priorities, forced survivor accounting,
lineage expiry, and stable population size. At generation 150 require fewer
neutral credit submissions than Phase 5A and at least one completed changed
comparison. At generation 300 compare:

- neutral submission and zero-delta rates;
- approvals among behavior-changing children;
- approved descendant depth within a lineage;
- positive global paired challengers and Stage-3 promotion;
- diversity against the Phase-5A trajectory.

If admission improves credit efficiency but approved lineages still produce no
descendant approvals or positive global challenger, bounded survival alone is
insufficient; do not silently extend its lifetime or weaken global promotion.

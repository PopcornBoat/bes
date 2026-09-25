# Phase 5A: Paired Official Return Credit

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


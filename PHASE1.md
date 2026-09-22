# Phase 1 Contract

Phase 1 answers only two questions:

1. Are DAgger trajectories and labels internally consistent?
2. Are official candidate comparisons sufficiently protected from noise?

## Invariants

- Teacher and learner queries are side-effect-free proposals.
- The semantic proposal is distinct from the concrete action finally executed.
- Scan state and used-Decoy state advance only from the real observation,
  bridge-resolved concrete action, and real transition.
- Teacher mixing records proposal disagreement and the source of the executed
  action independently.
- Official-guided DAgger uses an independent serialize/deserialize snapshot of
  the previous generation's ranked-imitation champion. The protected official
  incumbent is never reused as the evolving behavior policy.
- Training, racing, promotion, and reference seeds use disjoint namespaces and
  separately checkpointed cursors.
- Candidate and incumbent use the same initial seeds within every paired round.
  This is common-random-number comparison, not a claim that random events remain
  coupled after policies diverge.
- Promotion seeds are fresh, non-repeating, and never drawn from training or
  racing streams.
- Promotion Stage 1 (12 pairs) and Stage 2 (40 cumulative pairs) may reject only.
  Only Stage 3 (100 cumulative pairs) may promote.
- Roots 153, 42, and 2026 are monitoring only and never affect selection.
- Historical best graphs remain independent serialize/deserialize copies.
- Warm-start initialization never overwrites an existing incumbent checkpoint.
  Only an accepted Stage-3 official promotion may replace that file.
- Population survival remains the existing ranked-imitation selection. Phase 1
  does not introduce lexicase or mutation changes.

## Structured evaluation record

Every completed official challenger evaluation records:

- ranked imitation score;
- official candidate and incumbent episode returns;
- mean, standard deviation, and standard error;
- exact seeds and episode count;
- evaluation stage and decision;
- paired differences and standard error;
- same-seed return correlation;
- paired-difference variance and the corresponding independent variance sum.

## Success criteria

Phase 1 is successful when tests and controlled runs establish that:

1. querying either proposal cannot alter controller state;
2. resume continues every seed cursor exactly;
3. paired competitors receive identical seed blocks;
4. promotion never reuses training or racing seeds;
5. small lucky samples cannot directly replace historical best;
6. teacher mixing delays first disagreement and trajectory collapse;
7. pure-student behavior remains separately observable from mixed rollout;
8. measured paired variance can be compared directly with unpaired variance.

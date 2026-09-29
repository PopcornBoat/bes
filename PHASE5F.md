# Phase 5F: Bounded Near-Miss Lineages

Phase 5F is an isolated search-memory treatment for official-guided BES. It
does not weaken historical-best promotion, change grouped epsilon-lexicase,
or restore an old population. Warm start intentionally reconstructs a fresh
population around the independently serialized saved best; persisting an
entire population previously caused unacceptable memory use.

## Admission contract

A rejected challenger can become a detached lineage anchor only when all of
the following hold:

- its official evaluation completed through promotion Stage 4;
- aggregate and 100-step paired means are positive;
- CVaR and catastrophic-tail guards pass; and
- rejection is caused only by insufficient aggregate and/or 100-step
  confidence margin.

Exact Top-1 plus full-ranking behavior on the versioned probe archive is used
to reject duplicate basins. At most two lineages are active. Anchors and heads
are deep serialized policies stored under `.phase5f-near-miss/`; they never
enter `*teams*` and cannot overwrite the historical best.

## Variation and selection budget

Ten percent of otherwise native offspring opportunities may mutate a detached
lineage head. The ordinary native mutation implementation is reused in an
isolated team registry; only the resulting independent closure is inserted as
an ordinary population child. Phase 5F does not alter mutation probabilities,
directed-repair quotas, population size, grouped epsilon-lexicase, or survivor
protection.

At most one of every five official challenger slots is reserved for the best
available lineage descendant. If none exists, the slot returns to an ordinary
challenger. Lineage identity affects candidate budgeting only; it is not a
fitness bonus.

## Local head update

A lineage descendant first receives five paired screen episodes against its
current head. If it remains plausible, it receives a disjoint fresh block of
20 seeds over horizons 30, 50, and 100. It replaces the detached head only if:

- aggregate and 100-step paired improvement over the current head exceed one
  standard error;
- aggregate and 100-step means remain positive versus the immutable admission
  anchor; and
- 100-step CVaR and catastrophic counts do not regress versus either head or
  anchor.

A local head update is search memory only. Global incumbent replacement still
requires the unchanged fresh-seed, tail-aware Stage-4 promotion protocol.

## Lifetime and recovery

A lineage expires at the first of 250 persisted age generations, 80 lineage
reproduction opportunities, or 12 evaluated descendants. Updating its head
does not reset these lifetime budgets. Promotion clears all lineages tied to
the old incumbent.

The checkpoint/runtime journal stores seed cursors, counters, lineage evidence,
hashes, and paths to detached payloads. Resume validates incumbent identity and
payload hashes before restoring this small state. It deliberately does not
save or restore the complete population, normal mutation RNG state, or in-flight
worker processes.

The lineage evaluator uses its own recoverable seed namespace. Training,
racing, promotion, reference monitoring, legacy return-credit, and lineage
confirmation streams remain distinct.

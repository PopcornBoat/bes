# Phase 5E: Tail-Aware Multi-Horizon Promotion

## Scope

Phase 5E addresses one observed failure: a challenger promoted on 100 fresh
100-step episodes (`-24.505`) later produced `-32.8177 +/- 82.8725` over the
deterministic 1000-episode full validation. Short horizons improved, but rare
long-horizon failures made the full total worse than the protected Phase-4a
baseline.

This phase does not change TPG execution, DAgger, mutation, reproduction,
grouped epsilon-lexicase, locality control, teacher-directed repair, or the
controller. It changes only the evidence required to overwrite the historical
checkpoint.

## Stages

1. Racing: 5 fresh paired 100-step episodes; futile candidates stop.
2. Stage 1: cumulative 12 fresh paired 100-step episodes; reject only.
3. Stage 2: cumulative 40; reject only.
4. Stage 3: cumulative 100; reject only.
5. Stage 4: cumulative 1000 plus 30/50-step rollouts on the same seeds.

The final per-seed aggregate is `R30 + R50 + R100`. Promotion requires its
paired mean and the 100-step paired mean to each exceed two standard errors.
The candidate must also have no worse 100-step worst-decile CVaR and no more
returns at or below `-100` than the frozen incumbent.

## Records and invariants

Every horizon record stores mean, standard deviation, standard error, median,
5/10/25 percentiles, worst-10% CVaR, catastrophic threshold/count/rate, seeds,
paired differences, correlation, and paired/unpaired variance. The aggregate
record stores the complete tail-audit decision. Stage 4 alone may promote.

All stages use the persisted promotion stream. Monitoring roots 153, 42, and
2026 remain selection-free. The worker is asynchronous, the main search thread
alone installs a result, stale incumbent versions are rejected, and checkpoint
installation retains serialize/deserialize deep-copy semantics.

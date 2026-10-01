# BES Semantic-36 Policy Evolution

This repository extends the Common Lisp BES/TPG implementation for official
CAGE2 policy learning. The active research line evolves a standalone TPG
policy while keeping environment state, action availability, and concrete
Decoy scheduling in a deterministic Lisp controller.

The original implementation is based on
[bmcnns/cl-tpg](https://github.com/bmcnns/cl-tpg). This repository documents
only the extensions and research controls used by the current system.

## Current policy contract

The maintained configuration is intentionally narrow:

- official CAGE2 environment;
- B-line opponent;
- 62 policy inputs: 52 raw observations plus 10 scan-state values;
- 36 direct `(target, response)` terminals;
- responses: `ANALYSE`, `REMOVE`, `RESTORE`, and `DECOY`;
- stateless TPG execution;
- fixed three-step opening;
- controller-owned global Decoy schedule;
- deterministic Lisp heuristic teacher;
- learner-visited DAgger traces;
- ranked semantic imitation;
- behavioral-locality measurement and bounded mutation locality;
- grouped epsilon-lexicase survivor selection;
- paired official evaluation and fresh-seed staged promotion.

The bridge may transport 142 values, but the policy reads only the first 62.
The remaining 80 availability values belong to the controller and are not TPG
inputs. The TPG proposes ranked semantic actions. The controller resolves the
first executable proposal, applies the fixed global Decoy schedule when the
response is `DECOY`, and commits state only after the environment executes the
concrete action.

Controller protocol `CAGE2-LISP-CONTROLLER-V2` fixes an earlier mismatch: the
heuristic uses one global ordered list of `(target, Decoy option)` pairs, not a
separate option order for every target.

## Measured reference results

All values below are official `SINGLE-RED-FULL` validation with 1000 episodes
at each 30-, 50-, and 100-step horizon.

| Policy | 30 | 50 | 100 | Total |
|---|---:|---:|---:|---:|
| Evolved checkpoint with legacy Decoy scheduling | -4.9053 | -10.2822 | -26.6667 | -41.8542 |
| Same evolved checkpoint with Controller v2 | -4.7461 | -8.9800 | -19.5357 | **-33.2618** |
| Compiled heuristic TPG with Controller v2 | -4.4561 | -8.0130 | -16.4807 | **-28.9498** |

The validated deterministic graph is versioned at
`oracles/checkpoints/bline-62-36-compiled-heuristic.lisp`. It contains the
same versioned team/checkpoint representation as an evolved best team. To
regenerate it after changing the compiler, load
`oracles/compiled-bline-heuristic.lisp` and call:

```lisp
(cl-tpg::write-compiled-bline-heuristic-checkpoint
 "oracles/checkpoints/bline-62-36-compiled-heuristic.lisp")
```

The controller correction improved the unchanged evolved checkpoint by
`8.5924` reward and reduced its penalty by about 20.5%. The remaining gap to
the compiled heuristic is `4.3120`. The largest improvement appears at 100
steps, where the standard deviation fell from about `65.04` to `11.25`.

## Mainline execution order

1. Start from a protected best-team checkpoint. Warm start deliberately builds
   a fresh population around that team; full-population snapshots previously
   caused excessive memory use and are not the intended resume contract.
2. Generate teacher and learner-visited trajectories with the deterministic
   Lisp heuristic.
3. Score the whole population on the same ranked semantic rows.
4. Measure parent/child behavioral disruption on the probe archive.
5. Bound most mutation outcomes while retaining an explicit non-local
   exploration fraction.
6. Select survivors with grouped epsilon-lexicase so complementary specialists
   are not discarded by one aggregate mean.
7. Compare serious challengers against the protected incumbent using paired
   official seeds.
8. Use fresh, disjoint seed blocks for staged promotion. Early stages may only
   reject; the final stage decides promotion and includes long-horizon and tail
   checks.
9. Save an accepted historical best immediately using serialize/deserialize
   deep-copy semantics.
10. Confirm important checkpoints with independent full validation.

Mixed rollout return and ranked-imitation fitness are diagnostics. Neither can
replace official paired promotion evidence.

## Research history

The numbered stages below describe the experimental history. Stage numbers are
documentation labels only; active branches, files, protocols, and commands use
functional names.

### Phase 1 — trustworthy trajectories and comparison

Teacher queries became side-effect free, learner and teacher proposals were
separated from the action actually executed, seed streams were separated, and
official promotion used fresh staged seed blocks. This protected the incumbent
from lucky imitation candidates and exposed the gap between one-step agreement
and closed-loop return.

### Phase 2 — measure semantic disruption

Passive parent/child measurements showed that small genotype edits can produce
large policy changes. The probability of an official drop greater than 100
rose from `0.087` for probe-neutral changes to `0.379`, `0.556`, and `0.935`
across progressively larger behavioral-radius bins. Learner action changes
were the clearest high-risk event.

### Phase 3 — control semantic locality

Mutation outcomes were resampled into local, bounded, and unrestricted tiers.
The experiment confirmed the risk of large behavioral jumps, but an overly
strict schedule exhausted retries and produced too many probe-neutral children.
The retained mainline keeps bounded locality plus explicit exploration rather
than imposing a hard local-only limit.

### Phase 4 — preserve complementary specialists

Grouped epsilon-lexicase was the strongest evolutionary improvement. Compared
with scalar selection, it retained roughly 34 unique Top-1 fingerprints instead
of about two, maintained broad population-level teacher support, and improved
full validation from `-55.0362` to `-46.2352` in the controlled comparison.

Routing repair, specialist composition, and their combination were safe on the
probe archive but did not produce positive official promotions. They are not
enabled by the mainline configuration.

### Phase 5 — official credit and targeted correction

Paired parent/child return credit occasionally preserved useful descendants,
but protected lineages did not establish reliable cumulative improvement.
Rare-failure replay, counterfactual one-step correction, teacher-directed
repair, tail-aware promotion, and bounded near-miss lineages were evaluated
separately. Tail-aware multi-horizon promotion remains useful. The targeted
repair and near-miss mechanisms did not reliably improve official return and
are disabled by default.

### Phase 6 — compiled policy and controller audit

A deterministic heuristic was compiled into a standalone TPG. Its first result
was unexpectedly poor because the controller used per-target Decoy ordering.
Replacing that with the heuristic's true global schedule reproduced the
heuristic result at `-28.9498`. Re-evaluating the evolved checkpoint under the
same controller improved it from `-41.8542` to `-33.2618`. This established
controller/action resolution as a major source of the previous gap and left a
small, measurable TPG scheduling gap for future work.

## Running the system

The canonical checkout is `/home/hardison/bes` in WSL Ubuntu. The Python bridge
and interpreter are under `/home/hardison/venv-base`.

```bash
cd /home/hardison/bes
scripts/bes-doctor
scripts/bes-runtime start
scripts/bes-search submit experiments/official-guided-semantic36.sexp
```

Monitor or stop a search with:

```bash
scripts/bes-runtime status
scripts/bes-runtime attach
scripts/bes-search stop
```

Run focused checks or the core suite with:

```bash
scripts/bes-test tests/controller.lisp tests/compiled-bline-heuristic.lisp
scripts/bes-test --core
```

See [DESIGN.md](DESIGN.md), [EXPERIMENTS.md](EXPERIMENTS.md),
[CONTRIBUTING.md](CONTRIBUTING.md), and
[docs/wsl-workflow.md](docs/wsl-workflow.md) for the maintained interfaces.

## Checkpoints and historical archives

Best-team files contain the graph required for warm start and validation.
Saving only the accepted best is intentional: a warm start reconstructs a new
population to preserve diversity and avoid the memory cost of full-population
serialization. Historical bests must remain independent deep copies produced
through serialization and deserialization.

Old research branches, stage-specific documents, experiment requests, and the
pre-cleanup working tree are preserved outside the active repository as a
verified Git bundle and compressed snapshot. They are not part of the current
branch surface.

## Related repository

The Gymnasium bridge is maintained separately at
[PopcornBoat/custom-gym-for-bes](https://github.com/PopcornBoat/custom-gym-for-bes).

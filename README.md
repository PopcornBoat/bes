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
- donor-free multi-source evolved-candidate admission;
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
| Reduced-operator fresh evolution (gen 1353 checkpoint) | -4.7403 | -8.8295 | -20.4782 | **-34.0480** |
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

To compare an evolved checkpoint with the compiled heuristic on both policies'
official trajectories, use:

```bash
scripts/policy-disagreement-analysis \
  /path/to/evolved.lisp \
  oracles/checkpoints/bline-62-36-compiled-heuristic.lisp \
  /path/to/output \
  validation-bline-100
```

The named seed specification recovers the exact 1000-seed B-line-100 block
used by full validation. A comma-separated explicit seed list is also accepted.

The report separates semantic ranking disagreement from the concrete action
ultimately selected by the shared Controller. The same seed couples the initial
environment RNG state only; after policies diverge it is not an event-keyed
counterfactual replay.

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

### Evolved-candidate official admission

The maintained challenger gateway no longer assumes that the aggregate
imitation champion is the only policy worth official inspection. Every drained
admission cycle nominates up to eight evolved roots: one aggregate champion,
two grouped specialists, two farthest-first behavioral variants, one
late-trajectory critical candidate, and two random controls. Exact ranked-row
behavior duplicates are merged before evaluation. The random lane is sampled
from the remaining eligible pool and never receives survivor or reproduction
protection merely because it was sampled.

All nominations in a batch use the same two paired official seeds. This stage
is a negative filter, not a noisy promotion test: one episode can never reject,
and with two episodes a policy is rejected only when
`paired mean + 2*SE < -5` reward relative to the incumbent. Every uncertain,
mildly negative, or positive policy enters the unchanged
`5 / 12 / 40 / 100 / 1000` official racing queue. Only final Stage-4 evidence
may replace the protected historical best.

Admission and random nomination use separate deterministic seed streams. Their
cursors and cumulative per-lane counters are journaled with the official-guided
runtime state. The append-only `official-admission-history.lisp` records cheap
outcomes and full-racing outcomes so aggregate, specialist, behavioral,
critical, and random lanes can be compared by positive-return, Stage-1,
Stage-4, and promotion rates.

The old 400-generation proportional population restart remains loadable for
archaeology but is forced off by the maintained live profile; it is not part of
this experiment.

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

### Effective-local mutation and guarded compression

The next maintained treatment starts from the independently validated reduced
checkpoint and uses `experiments/effective-local-compression.sexp`. Program
mutation changes one opcode, destination, source type, source index, or
constant at a time; whole-instruction replacement remains a 5% escape path.
Eighty percent of instruction selections target the current R0 backward slice
and twenty percent retain unrestricted exploration. Learner, terminal, edge,
and graph mutation are unchanged.

Guarded compression is not periodic global pruning. At or after generation
1000, every 1000 generations it may deep-copy the protected incumbent only when
its intron ratio is at least 95%, the incumbent has not changed for at least
400 generations, and the previous event is at least 1000 generations old. The
compact copy must preserve every Top-k semantic ranking in the behavioral
probe archive. One verified compact root and local variants occupying at most
10% of the population are then injected; the historical best and its disk
checkpoint are never modified by this mechanism. R0-only compression is
disabled for recurrent policies.

A one-shot `:compression-reseed-force-next-event :enabled` request bypasses
only the generation, plateau, and cooldown schedule. It is consumed when graph
analysis begins; the intron threshold, stateless-only rule, independent deep
copy, exact probe-ranking equivalence, and capacity checks remain mandatory.

### Categorical read-only registers

The `read-only-registers` treatment warm-starts from a separately frozen,
effective-code-only copy of the independently validated `-33.7650` policy.
The source checkpoint remains untouched. The compact copy contains 13,089
instructions instead of 100,462 and produced identical complete semantic
rankings on 512 deterministic probes.

Set `:read-only-register-profile :cage2-categorical-v1` to expose four
source-only operands: `ROR0=0.0d0`, `ROR1=1.0d0`, `ROR2=2.0d0`, and
`ROR3=3.0d0`. They are not writable registers, do not change the eight-register
program state, cannot be instruction destinations, and do not introduce
recurrent memory. The profile is disabled by default. New random arguments use
an ROR with probability 0.20 when enabled; field-local mutation can separately
change an operand to/from ROR addressing or change only its ROR index. Existing
learner, terminal, team-edge, and graph mutation remain unchanged.

Checkpoints record both the ROR profile and the exact value bank. ROR runs use
their own filename component and checkpoint directory. The Python bridge and
Semantic-36 Controller contract are unchanged.

When `:categorical-predicate-mutation-enabled :enabled` is selected with the
`reduced-eq` instruction profile, 10% of field-local instruction mutations
atomically form `EQ(OBS-i, ROR-c)`. The edit preserves the selected
instruction's destination register while choosing the observation and category
stochastically. This crosses the multi-field predicate-construction valley
without choosing an action or bypassing normal TPG selection and official
promotion. The operator is disabled by default and recorded in checkpoint
metadata and filenames.

The controlled teacher-guided treatment uses
`:teacher-guided-predicate-injection-enabled :enabled`. It keeps random compound
predicate mutation disabled, derives repeated error groups from clean DAgger
diagnostics, and ranks `EQ(OBS-i, ROR-c)` gates by target coverage minus
collisions on the protected probe archive. A selected gate either raises an
existing direct Semantic-36 terminal or adds a minimal direct specialist when
the terminal is missing. A child must improve the diagnosed group and pass the
existing behavioral-locality and collateral-damage limits. At most one such
child receives first-evaluation grouped-selection protection, and a guided
challenger still has to pass the unchanged official paired promotion protocol.

The successor treatment uses
`:incumbent-conservative-repair-enabled :enabled`. It always clones the frozen
official incumbent, limits repairs to repeated early and step-10--29 Top-8
omissions, and adds one new direct Semantic-36 specialist. Two exact categorical
predicates are combined as an AND gate, and its bid is calibrated against the
incumbent instead of being saturated. A candidate is admitted only if it changes
no Top-1 decision over as many as 256 current on-policy background observations
plus the protected archive. Ordinary grouped selection and the unchanged fresh
paired official racing/promotion protocol remain authoritative. This switch is
mutually exclusive with the older population-parent guided treatment.

## Running the system

The canonical checkout is `/home/hardison/bes` in WSL Ubuntu. The Python bridge
and interpreter are under `/home/hardison/venv-base`.

```bash
cd /home/hardison/bes
scripts/bes-doctor
scripts/bes-runtime start
scripts/bes-search submit experiments/official-guided-semantic36.sexp
# ROR warm start from the frozen compact checkpoint:
scripts/bes-search submit experiments/read-only-registers.sexp
# Exact categorical predicates over observations/ROR values:
scripts/bes-search submit experiments/categorical-equality.sexp
# Atomically form complete EQ(OBS-i, ROR-c) predicates during mutation:
scripts/bes-search submit experiments/categorical-predicate-mutation.sexp
# Direct predicates toward repeated teacher disagreements:
scripts/bes-search submit experiments/teacher-guided-predicate-injection.sexp
# Incumbent-anchored two-predicate conservative repair:
scripts/bes-search submit experiments/incumbent-conservative-repair.sexp
# Multi-source evolved-candidate admission with random controls:
scripts/bes-search submit experiments/evolved-candidate-official-admission.sexp
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

Inspect a checkpoint's effective bid-producing instructions without modifying
the graph:

```bash
scripts/bes-effective-code CHECKPOINT [REPORT.txt] [OUTPUT-REGISTERS]
```

`OUTPUT-REGISTERS` is a comma-separated list of internal zero-based register
indices and defaults to the bid register (`0`). That default is correct for the
maintained stateless Semantic-36 policy, whose terminal stores target and
response directly. Legacy register-decoded policies should include every
register that contributes to their output, for example `0,1,2`. The analyzer
reports the exact backward slice but does not remove instructions or alter the
checkpoint.

The search menu exposes two instruction-creation profiles:

- `full`: the historical 11-opcode set;
- `reduced`: `ADD`, `SUB`, `MUL`, and `DIV` only.

The reduced profile is an ablation based on the operators sufficient to encode
the compiled B-line heuristic. It restricts fresh programs and newly added
instructions; it never rewrites instructions already present in a warm-start
checkpoint. Checkpoints record the profile, include it in their filename, and
discard a stored fitness as non-comparable when resumed under a different
profile. Execution remains able to load and run every historical opcode.

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

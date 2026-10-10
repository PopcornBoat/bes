# Maintained Experiment Procedures

## Official-guided training

The checked-in request is:

```text
experiments/official-guided-semantic36.sexp
```

It uses the maintained contract:

```text
environment: Cage2-b_line-100-v0
observations: 62
actions: 36
memory: stateless
opening: fixed
Decoy schedule: fixed global heuristic order
rollout: DAgger
teacher: Lisp heuristic
instruction set: full
Hamming projection: disabled
fitness episodes: 5
```

Before starting:

```bash
cd /home/hardison/bes
scripts/bes-doctor
scripts/bes-test --core
scripts/bes-runtime start
scripts/bes-search submit experiments/official-guided-semantic36.sexp
```

Monitor with:

```bash
scripts/bes-runtime status
scripts/bes-runtime capture
scripts/bes-runtime attach
```

Request a graceful stop with:

```bash
scripts/bes-search stop
```

## Instruction-set ablation

Task B compares fresh searches under the historical opcode catalogue and the
four-opcode arithmetic core. The paired requests differ only in profile and
checkpoint directory:

```bash
scripts/bes-search submit experiments/instruction-set-full.sexp
scripts/bes-search submit experiments/instruction-set-reduced.sexp
```

Run them separately on the same code revision. Both use search root `153`, so
the experiment begins from reproducible random streams, but official promotion
still uses its independent racing and promotion streams. Do not warm-start the
strict ablation from a full-profile checkpoint: inherited instructions remain
executable by design and would make that run a mixed instruction-set treatment.

Compare generation time, effective-code ratio, ranked imitation, diversity,
official paired promotion outcomes, and independent 30/50/100-step validation.
The reduced treatment succeeds only if it preserves or improves official
return—not merely if it produces smaller or faster programs.

## Effective-local mutation with compression/reseed

The checked-in warm-start request is:

```text
experiments/effective-local-compression.sexp
```

It starts from the frozen reduced-operator checkpoint whose independent full
validation is `-34.0480`. Its instruction mutation contract is:

```text
95% field edit:
  opcode within ADD/SUB/MUL/DIV
  destination register
  source type
  source index
  constant perturbation

5% whole-instruction replacement

instruction selection:
  80% from the effective R0 backward slice
  20% from the complete program
```

In `:FIELD-LOCAL` mode, the legacy instruction add/delete/swap probabilities
are retained in requests for format compatibility but are not applied. The
ordinary learner add/delete, terminal mutation, team-edge mutation, learner
action swap, and graph behavior remain active.

Compression/reseed uses protocol `COMPRESSION-RESEED-V1` with fixed gates:

```text
minimum generation:        1000
scheduled interval:        every 1000 generations
minimum intron ratio:      0.95
incumbent plateau:         400 generations
event cooldown:            1000 generations
maximum injected roots:    10% of population
```

Only a serialize/deserialize deep copy of the protected incumbent is pruned.
The compact graph is injected only after exact Top-k ranking equality on the
current versioned probe archive. Its variants pass through the same native
mutation and semantic-locality control as other offspring. No event overwrites
the historical checkpoint or prunes the existing population in place.

For a controlled one-shot attempt after a measured plateau, submit:

```text
experiments/forced-effective-local-compression.sexp
```

Its `:compression-reseed-force-next-event :enabled` flag bypasses only the
schedule and is consumed when analysis starts. It cannot bypass the 95% intron
threshold, stateless-only rule, deep serialization copy, exact probe-ranking
equivalence, or bounded population injection. Subsequent events return to the
1000-generation schedule relative to the last successful event.

Run with:

```bash
scripts/bes-runtime start
scripts/bes-search submit experiments/effective-local-compression.sexp
```

Monitor `compression-and-reseed` telemetry, instruction counts before/after,
probe count, event generation, subsequent diversity, and official promotions.

## Plateau-triggered population diversity pulse

`experiments/population-diversity-pulse.sexp` tests whether the repeated
post-warm-start improvements are caused by renewed population coverage. It
starts from the independently validated evolved v13 incumbent and leaves all
targeted repair and compression injections disabled.

The `LIVE-DIVERSITY-V2` search profile also leaves behavioral-locality worker
sampling and semantic-locality retry control dormant. Grouped epsilon-lexicase,
ranked clean DAgger, disagreement reporting, field-local/effective-aware
mutation, Controller v2, and official staged promotion remain active. Legacy
mechanism definitions stay loadable for checkpoint archaeology, but the live
server rejects requests that attempt to reactivate those superseded treatments.

After 400 generations without an official promotion, the search performs a
50% partial warm restart. At the default population of 160, it retains 80 live
roots, removes the other 80 and their newly orphaned subgraphs, then fills the
80 vacated slots with one independent serialize/deserialize copy of the
protected incumbent plus 79 fresh random roots. Root population remains 160.
A promotion resets the plateau clock, and pulses have a 400-generation
cooldown. Setting the wipe fraction to 1.0 gives the originally considered
complete warm-start reconstruction; smaller values preserve more evolved
population diversity.

Root selection and rebuilt roots use a deterministic event-local RNG stream
derived from the search seed. They do not consume the ordinary mutation RNG,
overwrite the historical best, change official racing/promotion, or serialize
the complete population. Copied closures are normalized so only their intended
top team is evaluated as a root. Checkpoint metadata records the wipe fraction
and pulse provenance, while warm-start resume intentionally begins a new
run-local pulse schedule because population reconstruction is itself a
diversity event.

Run with:

```bash
scripts/bes-runtime start
scripts/bes-search submit experiments/population-diversity-pulse.sexp
```

The v2 run writes to
`/home/hardison/checkpoints/semantic36/population-partial-restart-50/` so its
candidate records and seed-stream cursors cannot mix with the archived v1 run.

Compare the first 400-generation baseline with each post-pulse interval. The
primary outcomes are final official promotions per interval and independent
full validation; imitation fitness, mixed return, and diversity diagnostics
remain explanatory rather than promotion criteria.

The completed 2666-generation run produced 229 official candidate evaluations
and no promotions despite repeated 50% restarts. Population coverage alone is
therefore not retained as an active treatment.

## Compiled heuristic donor seeding

`experiments/compiled-heuristic-donor.sexp` tests whether the remaining gap is
primarily a discoverability problem. It warm-starts from the protected evolved
v13 incumbent and replaces 10% of the freshly reconstructed roots with mutated
descendants of the compiled heuristic checkpoint.

The compiled checkpoint is only an unregistered parent. It is never inserted,
evaluated, promoted, or saved. Every admitted descendant must differ from the
compiled parent on the versioned probe archive and remain within the configured
Top-1 Hamming bound. Cohort construction uses a deterministic independent RNG
stream, leaving ordinary mutation RNG untouched. Subsequent descendants use the
normal learner, terminal, team-edge, graph, and field-local mutation pipeline.

Warm-start injection also normalizes every referenced checkpoint team to
`:internal`; only the designated checkpoint entry remains a root. This prevents
stale serialized type tags from making internal subgraphs compete as independent
policies or inflating the configured population.

Run with:

```bash
scripts/bes-runtime start bes-compiled-donor
scripts/bes-search submit experiments/compiled-heuristic-donor.sexp
```

Interpretation is deliberately asymmetric:

- descendants survive and improve: useful structure was hard to discover;
- descendants imitate well but fail official promotion: the selection objective
  still rewards the wrong behavior or tail risk;
- descendants disappear immediately: current population pressure cannot preserve
  the useful routing scaffold;
- evolved descendants beat the compiled reference: the scaffold can support
  improvement without deploying the hand-written policy itself.

## Evidence to monitor

Do not judge a run from mixed return or imitation fitness alone. Record:

- ranked-imitation score and executable accuracy;
- proposal disagreement and first-disagreement step;
- teacher-action Top-k support;
- unique action and ranking fingerprints;
- pairwise behavioral distance and entropy;
- locality tier, retry, fallback, and neutral-child rates;
- official paired candidate/incumbent deltas;
- promotion stage, seed block, mean, standard error, and tail metrics;
- 30-, 50-, and 100-step independent validation.

Stop immediately for graph corruption, population deficit, checkpoint
incompatibility, invalid seed-stream state, or controller-protocol mismatch.

## Full validation

Important checkpoints must be evaluated in a clean independent SBCL process
under Controller v2. `SINGLE-RED-FULL` runs 1000 episodes for each 30-, 50-,
and 100-step horizon and reports the three means, standard deviations, and
their summed total.

The current evolved reference under Controller v2 is `-33.2618`; the compiled
heuristic TPG reference is `-28.9498`. A training promotion score is not a
replacement for this independent full validation.

## Reproducibility

- Keep generated results outside the repository.
- Preserve the exact source checkpoint before a treatment.
- Keep training, racing, promotion, and monitoring seed streams disjoint.
- Resume seed-stream cursors from their saved state when the protocol matches.
- Reconstruct the population around the saved best during warm start.
- Never replace a protected checkpoint without final-stage evidence.

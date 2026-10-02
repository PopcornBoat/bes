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

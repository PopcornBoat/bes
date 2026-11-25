# Reproducible experiments

## Reference checkpoints

Frozen B-line and Meander checkpoints, checksums and official full-validation scores are listed in [validated-checkpoints/README.md](validated-checkpoints/README.md). Do not overwrite these files. Record the checkpoint hash, controller protocol, opponent, seed root and horizon for each comparison.

## Commands

Run the maintained tests:

```bash
scripts/bes-test
scripts/bes-test --core
```

Check local environment paths:

```bash
scripts/bes-doctor
```

Launch teacher-free official training from the protected reference checkpoint:

```bash
scripts/run-bline-official-online /home/hardison/bes-artifacts/runtime/bline-online-run
scripts/run-meander-official-online /home/hardison/bes-artifacts/runtime/meander-online-run
```

Run one launcher for the desired opponent and pass a new or empty run directory. The B-line launcher uses frozen v14 and port 8083. The Meander launcher uses frozen v9 and port 8082. Each writes its request and logs into the run directory. Use independent full validation and fresh seeds to assess a promoted checkpoint; generation best, imitation score and mixed return alone are not official validation.

## Teacher-guided DAgger

From the `offline-dagger` worktree, start a BES server with `scripts/bes-runtime start`. Submit an opponent-specific request with `scripts/bes-search submit REQUEST.sexp`.

- B-line v14 route uses `experiments/evolved-candidate-official-admission.sexp` to warm-start from the protected v13 checkpoint.
- Meander v8 route uses `experiments/meander-heuristic-official-guided.sexp` to start a fresh heuristic-guided population.

Check the input checkpoint path (if applicable) and set a separate output directory in the request before submitting it. The Lisp mode name for these DAgger requests is `:official-guided`. The teacher-free launchers select `:official-online`.

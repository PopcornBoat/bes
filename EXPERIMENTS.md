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
scripts/run-bline-official-online
scripts/run-meander-official-online
```

The launchers accept their existing checkpoint/configuration overrides. Review their help and current `experiments/*.sexp` settings before a long run. Follow telemetry from the run directory. Use independent full validation and fresh seeds to assess a promoted checkpoint; generation best, imitation score and mixed return alone are not official validation.

For teacher-guided starting point training, switch to `offline-dagger` and use the maintained official-guided configuration. Do not mix teacher labels into the online workflow.

# WSL Workflow

The authoritative checkout is `/home/hardison/bes`.

## Health check

```bash
cd /home/hardison/bes
scripts/bes-doctor
```

## Server lifecycle

```bash
scripts/bes-runtime start
scripts/bes-runtime status
scripts/bes-runtime attach
scripts/bes-runtime capture
scripts/bes-runtime stop
```

## Search lifecycle

```bash
scripts/bes-search submit experiments/official-guided-semantic36.sexp
scripts/bes-search stop
```

The stop command is graceful. Allow the active generation or checkpoint write
to reach a safe boundary before considering process-level intervention.

## Tests

```bash
scripts/bes-test tests/controller.lisp
scripts/bes-test tests/compiled-bline-heuristic.lisp
scripts/bes-test --core
```

## Generated data

Keep checkpoints under `/home/hardison/checkpoints`, datasets under
`/home/hardison/.datasets`, and generated analysis/validation evidence under
`/home/hardison/bes-artifacts` or `/home/hardison/backup`. Do not commit these
artifacts.

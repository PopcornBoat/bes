# WSL-First BES Workflow

## Open the canonical project

The source of truth is:

```text
/home/hardison/bes
```

From Windows, open the same files through:

```text
\\wsl.localhost\Ubuntu\home\hardison\bes
```

Do not maintain a second active clone on a Windows drive. For a native Linux
Codex session:

```bash
cd /home/hardison/bes
codex
```

At the beginning of a new task, verify the execution context:

```bash
./scripts/bes-doctor
```

## Standard operations

Start a server when port 8080 is free:

```bash
./scripts/bes-runtime start bes
```

Inspect or attach to it:

```bash
./scripts/bes-runtime status
./scripts/bes-runtime capture bes
tmux attach -t bes
```

Submit a version-controlled experiment request:

```bash
./scripts/bes-search submit experiments/phase4b-b-specialist-composition.sexp
```

Request a graceful stop:

```bash
./scripts/bes-search stop
```

The stop request does not kill SBCL. Wait for the `Search stopped` message or
verify that no search worker remains before replacing the server.

Run focused regression checks:

```bash
./scripts/bes-test tests/phase4b-specialist-composition.lisp
./scripts/bes-test --core
```

## Runtime and source separation

Runtime output is never written into Git:

```text
/home/hardison/checkpoints    experiment checkpoints and journals
/home/hardison/backup         protected experiment sources
/home/hardison/.datasets      datasets
/home/hardison/bes-artifacts  local/private artifacts
```

Each treatment receives a new checkpoint directory. A checked-in request file
documents the exact source checkpoint, parameters, action contract, seed, and
destination directory used for a reproducible run.

## Git authentication

Both BES and the Python bridge use SSH remotes inside WSL. Verify without
changing repository state:

```bash
git ls-remote --exit-code origin HEAD
```

Do not store a GitHub PAT, WSL password, or private key in the repository or in
experiment files.


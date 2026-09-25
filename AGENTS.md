# BES Working Agreement

## Canonical environment

- The authoritative checkout is `/home/hardison/bes` in WSL Ubuntu.
- Do not edit or create Git worktrees under `/mnt/c` or `/mnt/d` for BES work.
- Windows access is read/review convenience through
  `\\wsl.localhost\Ubuntu\home\hardison\bes`; it is not a second checkout.
- The Python bridge checkout is `/home/hardison/venv-base` and its interpreter
  is `/home/hardison/venv-base/cage2_bridge/.venv/bin/python`.
- Datasets live under `/home/hardison/.datasets`; checkpoints live under
  `/home/hardison/checkpoints`; large or private artifacts live outside the
  repository under `/home/hardison/bes-artifacts` or `/home/hardison/backup`.

## Before changing code

1. Read `docs/chat-handoff.md` and inspect the current branch/status.
2. Check for active SBCL, Emacs, tmux, validation, and evaluator processes.
3. Do not stop or replace an active experiment unless the user asks.
4. Preserve protected source checkpoints and their matching runtime journals.

## Git conventions

- Branch names must not use a `codex/` prefix.
- Commit messages must not mention Codex, AI, or an agent prefix.
- Never commit checkpoints, datasets, trained teacher models, private teacher
  implementations, runtime logs, or generated experiment artifacts.
- Prefer SSH Git remotes so WSL never invokes Windows Credential Manager.
- Keep experiments causally isolated: start comparison treatments from their
  documented protected source, not from another treatment's descendant.

## Runtime workflow

- Use `scripts/bes-runtime` to start, inspect, attach to, or capture the SBCL
  server. The server listens on port 8080.
- Use `scripts/bes-search` to submit a checked-in experiment request or request
  a graceful search stop.
- Use `scripts/bes-doctor` before a long operation or when environment state is
  uncertain.
- Keep long searches in tmux. Do not block an agent turn merely to wait for a
  generation threshold; report the session, stop criteria, and monitoring
  commands to the user.
- A stop-search request is graceful and may take time to reach a safe boundary.
  Never kill SBCL while it is saving or promoting a checkpoint.

## Verification

- Run focused checks with `scripts/bes-test` and optional test file arguments.
- For a broad non-simulator regression pass, run `scripts/bes-test --core`.
- Do not run costly CAGE2 experiments or full validation unless requested.
- Report exactly what was run; do not describe unrun experiments as tested.

## Research invariants

- The current policy contract is 62-input, stateless, direct Semantic-36
  target/response terminals with controller-owned fixed Decoy ordering.
- Teacher/controller state changes only from the concrete action actually
  executed by the environment.
- Historical bests retain serialize/deserialize deep-copy semantics.
- Official paired racing and fresh 12/40/100 promotion, not mixed return or
  imitation fitness alone, decide incumbent replacement.
- Phase-specific frozen controls and attribution rules are documented in
  `DESIGN.md`, `PHASE1.md` through `PHASE4B.md`, and `EXPERIMENTS.md`.

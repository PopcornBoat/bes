# BES Working Agreement

## Canonical environment

- The authoritative checkout is `/home/hardison/bes` in WSL Ubuntu.
- Do not develop BES in a second Windows checkout.
- The bridge checkout is `/home/hardison/venv-base`; its interpreter is
  `/home/hardison/venv-base/cage2_bridge/.venv/bin/python`.
- Datasets live under `/home/hardison/.datasets`; checkpoints live under
  `/home/hardison/checkpoints`; generated evidence and private artifacts live
  outside the repository under `/home/hardison/bes-artifacts` or
  `/home/hardison/backup`.

## Before changing code

1. Read `docs/research-status.md` and inspect branch/status.
2. Check for active SBCL, Emacs, tmux, validation, and evaluator processes.
3. Do not stop or replace an active experiment without an explicit decision.
4. Preserve protected checkpoints and their matching runtime journals.

## Version-control conventions

- Branches and files use functional names, not stage numbers or tool names.
- Commit messages describe the implementation and never include automation
  branding or authorship markers.
- Never commit checkpoints, datasets, trained models, private teacher code,
  runtime logs, or generated experiment artifacts.
- Use the SSH remote in WSL.
- Start comparison treatments from their documented protected source rather
  than from another treatment's descendant.

## Runtime workflow

- Use `scripts/bes-runtime` to start, inspect, attach to, or capture the server.
- Use `scripts/bes-search` to submit a checked-in experiment request or request
  a graceful stop.
- Use `scripts/bes-doctor` before a long operation or after environment changes.
- Keep long searches in tmux.
- A stop request is graceful and may take time to reach a safe boundary. Never
  terminate SBCL while it is saving or promoting a checkpoint.

## Verification

- Run focused checks with `scripts/bes-test` and explicit test paths.
- Run `scripts/bes-test --core` for the broad non-simulator regression suite.
- Run official CAGE2 experiments or full validation only when required.
- Report exactly what ran; do not describe unrun experiments as tested.

## Research invariants

- The policy contract is 62-input, stateless, direct Semantic-36 terminals.
- The controller owns the fixed global Decoy schedule and concrete action
  availability.
- Controller state changes only from the action actually executed.
- Historical bests retain serialize/deserialize deep-copy semantics.
- Official paired racing and fresh staged promotion decide incumbent
  replacement; mixed return and imitation fitness do not.
- Warm start intentionally reconstructs the population around the saved best.

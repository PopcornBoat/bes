# BES Research Handoff

Updated: 2026-09-25

## Canonical state

- Repository: `/home/hardison/bes`
- Branch: `specialist-composition`
- Active experiment code commit: `df63c6f`
- Python bridge: `/home/hardison/venv-base`
- Bridge branch: `official-guided-dagger`
- Policy contract: 62 observations, direct Semantic-36 target/response
  terminals, fixed opening, fixed controller-owned Decoy order, stateless TPG.

Read `AGENTS.md`, `DESIGN.md`, `PHASE4B.md`, and the Phase-4 sections of
`EXPERIMENTS.md` before modifying the active research path.

## Established result

Phase 4a grouped epsilon-lexicase produced the current protected incumbent:

```text
/home/hardison/backup/official-guided/phase4a-grouped-lexicase-gen1003/
bline-62-36-official-guided-grouped-lexicase-order-fixed-teacher-heuristic-opening-fixed-hamming-off-memory-stateless.lisp
```

Its official incumbent mean is `-25.871`. Deterministic full validation total
was `-46.2352`. It materially outperformed the scalar control while preserving
many complementary behavioral fingerprints.

Phase 4b-A routing repair ran for about 508 generations. Repairs were safe and
local, and absent-from-Top8 improved modestly, but no challenger passed Stage-3
promotion. The population retained broad distributed support, motivating
specialist composition rather than more single-bidder repair.

## Active experiment: Phase 4b-B

The run is an isolated specialist-composition treatment from the protected
Phase-4a source above, not from a Phase-4b-A descendant.

```text
tmux session: phase4bb
TCP port:     8080
output:       /home/hardison/checkpoints/semantic36/phase4b-b-specialist-composition/
request:      experiments/phase4b-b-specialist-composition.sexp
```

Phase 4b-B reserves 10% of offspring slots for systematic Case-B1 repair. It
first attempts to attach a live group-qualified donor through a cycle-safe team
reference. A direct Semantic-36 terminal is an explicitly logged fallback only
when no donor qualifies. All children still pass target-group improvement,
collateral, locality, grouped epsilon-lexicase, official racing, and fresh-seed
promotion gates.

Monitor:

```bash
./scripts/bes-runtime status
./scripts/bes-runtime capture phase4bb
tmux attach -t phase4bb
```

Decision points:

- Stop immediately for a crash, checkpoint/runtime mismatch, cycle,
  population deficit, or donor reference/root-status leak.
- At generation 50, require scheduled attempts and at least one safe accepted
  composition or an accurately logged terminal fallback.
- At generation 100, revise if acceptance is below about 1%, no team-reference
  composition is accepted, and Case-B1/absent-Top8/first-disagreement metrics
  do not improve.
- Otherwise make the first controlled decision at generation 300--500.
- Strong evidence requires repeated safe reference composition, preserved
  population diversity, improved trajectory diagnostics, and ideally a
  Stage-3 promotion over `-25.871`.

Mixed rollout return and imitation/ranking scores remain diagnostics. They do
not replace official paired promotion evidence.

## Frozen research sequence

1. Phase 1 made teacher/student trajectories and candidate comparison
   trustworthy.
2. Phase 2 measured genotype-to-behavior disruption without changing mutation.
3. Phase 3 controlled semantic locality using the measured evidence.
4. Phase 4a introduced grouped epsilon-lexicase to preserve complementary
   specialists.
5. Phase 4b tests error-directed variation, first routing repair and now
   specialist composition.

Do not mix recurrent TPG, new action spaces, digital-twin fitness, or new
selection mechanisms into the Phase 4b-B comparison.


# BES Research Handoff

Updated: 2026-09-25

## Canonical state

- Repository: `/home/hardison/bes`
- Branch: `official-return-credit`
- Active experiment: Phase 5A paired official return credit
- Python bridge: `/home/hardison/venv-base`
- Bridge branch: `official-guided-dagger`
- Policy contract: 62 observations, direct Semantic-36 target/response
  terminals, fixed opening, fixed controller-owned Decoy order, stateless TPG.

Read `AGENTS.md`, `DESIGN.md`, `PHASE4B.md`, `PHASE5.md`, and the Phase sections of
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

## Completed experiment: Phase 4b-B

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

The run stopped cleanly at generation 640. Analysis through generation 626
found 210 accepted repairs from 5,022 attempts, with zero target-group Top-1
losses and zero collateral exact losses. Diversity remained healthy, but none
of 62 official outcomes promoted; five Stage-3 challengers were all worse than
the protected `-25.871` incumbent.

## Completed experiment: Phase 4b-C

Phase 4b-C combines the already measured operators from the same protected
Phase-4a source. A single ten-percent quota dispatches Case A to routing repair
and Case B1 to specialist composition. It does not use a Phase-4b descendant.

```text
tmux session: phase4bc
TCP port:     8080
output:       /home/hardison/checkpoints/semantic36/phase4b-c-combined-repair/
request:      experiments/phase4b-c-combined-repair.sexp
```

Monitor with `./scripts/bes-runtime status`, `./scripts/bes-runtime capture
phase4bc`, or `tmux attach -t phase4bc`. The first controlled decision remains
generation 300--500. Strong evidence requires sustainable trajectory gains and
at least one positive official paired challenger, ideally a Stage-3 promotion.

The run stopped cleanly after generation 574. It accepted 115 of 4,654 repair
slots (2.47%) and recorded 951 target-group Top-1 gains with no measured
target or collateral exact loss. Late imitation diagnostics improved, but all
57 official challengers were rejected and none had a positive paired return
delta. Safe teacher-directed proposal generation alone did not create
environment-level improvement.

The next isolated treatment is Phase 5A official return credit. It starts from
the protected Phase-4a checkpoint, disables all Phase-4b targeted repair, and
retains Phase-3 locality plus Phase-4a grouped epsilon-lexicase. Paired official
child-versus-direct-parent evidence will be allowed to preserve a return-
approved child in the live population; global incumbent replacement remains
the existing fresh 12/40/100 promotion protocol.

## Frozen research sequence

1. Phase 1 made teacher/student trajectories and candidate comparison
   trustworthy.
2. Phase 2 measured genotype-to-behavior disruption without changing mutation.
3. Phase 3 controlled semantic locality using the measured evidence.
4. Phase 4a introduced grouped epsilon-lexicase to preserve complementary
   specialists.
5. Phase 4b tested error-directed routing, composition, and their combination;
   all were safe but failed to improve official return.
6. Phase 5A tests official paired parent-to-child return credit without
   Phase-4b proposal operators.

Do not mix recurrent TPG, new action spaces, digital-twin fitness, Phase-4b
targeted proposal operators, or another selection mechanism into Phase 5A.

## Active experiment: Phase 5A

Phase 5A starts from the protected Phase-4a checkpoint. It disables Phase-4b
targeted repair and adds a separate 5-then-20 paired official child/direct-
parent credit path. A statistically positive child receives one population
anchor opportunity; only the unchanged fresh 12/40/100 promotion may replace
the historical incumbent.

```text
tmux session: phase5a
TCP port:     8080
output:       /home/hardison/checkpoints/semantic36/phase5a-official-return-credit/
request:      experiments/phase5a-official-return-credit.sexp
```

Monitor the first completed credit decisions, stable root accounting, absence
of Phase-4b repair records, and positive child-parent deltas. The first safety
review is generation 50, the first mechanism review is generation 100, and the
first performance decision is generation 300--500.

# BES policy evolution

BES trains standalone Semantic-36 TPG policies for official CAGE2. The maintained policy reads 62 inputs (52 raw observations and 10 scan-state values), proposes ranked `(target, response)` actions, and uses the deterministic Controller for action availability and fixed Decoy order. B-line and Meander have separate policies and opponent-specific Controller settings.

## Maintained branches

[Validated pipeline and flowchart](docs/validated-pipeline.md) covers the evidence from offline training to the final complete agent.

| Branch | What to reproduce | Entry point |
| --- | --- | --- |
| main | Full pipeline and frozen complete-agent release | scripts/bes-search --help |
| [offline-dagger](https://github.com/PopcornBoat/bes/tree/offline-dagger) | Teacher-guided DAgger | [Training requests](docs/offline-dagger.md) |
| [online-official-specialists](https://github.com/PopcornBoat/bes/tree/online-official-specialists) | Teacher-free official search | [Online training](docs/online-official.md) |
| [tpg-analysis](https://github.com/PopcornBoat/bes/tree/tpg-analysis) | Graph and bid analysis, pruning, traces and figures | [Analysis](scripts/tpg_research/README.md) |
| [tpg-compilation](https://github.com/PopcornBoat/bes/tree/tpg-compilation) | Native compilation of exact ranked catalogues | [Compiler](scripts/tpg_compilation/README.md) |
| [extreme-optimize](https://github.com/PopcornBoat/bes/tree/extreme-optimize) | Decoy-order search, native ranking edits and held-out validation | [Optimizer](scripts/bes_extreme/README.md) |

All workflows share the BES core and checkpoint format. The historical DAgger and online requests explicitly select the original Controller resolution profile.

## Reproduce the frozen complete agent

The release tag contains the Controller, opponent router, two expert graphs and verified evidence. The archived official root-153 score is **-56.6674**. Use the pinned CybORG 2.1 bridge, SBCL and the ASDF dependencies.

~~~bash
scripts/bes-search materialize root153 /tmp/bes-root153
scripts/bes-search validate /tmp/bes-root153 /tmp/bes-root153-validation
~~~

The official evaluator uses 1,000 episodes per opponent and horizon by default. Use --episodes 2 for a small installation smoke. The separate Meander compilation reference is available through materialize meander-v15-reference. See [EXPERIMENTS.md](EXPERIMENTS.md) for score protocols and checkpoint provenance.

## Policy and checkpoint invariants

The terminal action is one of 36 target-response combinations. Register 0 determines bidding; the final terminal learner determines the selected semantic action. The Controller owns Decoy availability, the global fixed Decoy order, fallback resolution and state updates after actual execution. The bridge converts the resolved semantic action to a concrete CAGE2 action. Policy input stays at 62 even when the bridge transports additional Controller availability fields.

A saved best is an independent serialized graph copy. Warm start intentionally reconstructs a population around that best team rather than resuming the full population. Historical-best replacement requires staged official comparison on fresh paired seeds. Checkpoints in `validated-checkpoints/` are immutable reference material.

## Workflow

1. Set up the official CAGE2 Python bridge and confirm the WSL paths with `scripts/bes-doctor`.
2. For teacher-guided training, use the `offline-dagger` worktree and the opponent-specific request in [EXPERIMENTS.md](EXPERIMENTS.md).
3. For teacher-free online training, use `online-official-specialists` and a protected checkpoint. The B-line and Meander launchers are `scripts/run-bline-official-online` and `scripts/run-meander-official-online`.
4. Follow the run with Emacs telemetry or the launcher log. Perform independent full validation before calling a checkpoint successful.
5. Use `scripts/bes-test` for the maintained core suite and `scripts/bes-test --core` for the expanded suite.

See [validated-checkpoints/README.md](validated-checkpoints/README.md) for frozen policies and measured results. See [experiments/teacher-free-online-specialists.md](experiments/teacher-free-online-specialists.md) and [experiments/experience-guided-analysis.md](experiments/experience-guided-analysis.md) for the online method.

### CAGE2 Decoy scheduling

The Controller follows the proposed Top-8 host order once it reaches a Decoy.
Each proposed Decoy host uses its configured option order. When all proposed
Decoy hosts are exhausted, the Controller resumes the normal non-Decoy
fallback. Restore remains eligible only at Top-1. Scores obtained under an
earlier schedule require a new evaluation before comparison.

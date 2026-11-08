# BES policy evolution

This research branch retains [fixed-seed privileged official search](docs/privileged-official-search.md) and [Controller-aligned repair credit](docs/controller-aligned-repair.md) as completed experiments. The current bounded experiment is the [closed-loop nomination pilot](experiments/closed-loop-nomination-pilot.md).

BES trains standalone Semantic-36 TPG policies for official CAGE2. The maintained policy reads 62 inputs (52 raw observations and 10 scan-state values), proposes ranked `(target, response)` actions, and uses the deterministic Controller for action availability and fixed Decoy order. B-line and Meander have separate policies and opponent-specific Controller settings.

## Maintained branches

- `main`: repository baseline.
- `offline-dagger`: teacher-guided DAgger, ranked imitation, grouped selection and official promotion. This is the path that produced the pre-online starting checkpoints.
- `online-official-specialists`: teacher-free online evolution from a protected checkpoint. Official return drives admission and promotion; structural opportunity analysis can generate conditional specialist offspring.

The two experimental branches share the same policy/checkpoint format and most of the source code. The branch name identifies the maintained workflow, while the runtime mode selects teacher-guided or teacher-free training.

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

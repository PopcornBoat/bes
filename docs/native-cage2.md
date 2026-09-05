# Native Lisp cage2-mini backend

## Architecture

BES supports three independent CAGE2 execution paths:

| Menu name | Environment implementation | Python during rollout | Intended use |
| --- | --- | --- | --- |
| `Cage2-*` | Official CybORG | yes | final evaluation and tuning |
| `Cage2Mini-*` | Python cage2-mini | yes | compatibility and bridge comparison |
| `Cage2Lisp-*` | Native Lisp cage2-mini | no | high-throughput training and fast validation |

The native backend does not replace or modify the other paths. Public
`cl-gym:rollout` dispatches only registered `Cage2Lisp-*` names to Lisp;
every other environment continues through the existing Gymnasium/Py4CL2 path.

Each native rollout owns its environment and 52-element conversion buffer.
This is required because BES evaluates teams in parallel and cage2-mini state
is mutable.

## Clone and update

The Lisp environment is pinned as the `vendor/cage2-mini` Git submodule.
Clone BES with:

```powershell
git clone --recurse-submodules https://github.com/PopcornBoat/bes.git
```

For an existing checkout:

```powershell
git submodule update --init --recursive
```

To update the pinned environment deliberately:

```powershell
git submodule update --remote vendor/cage2-mini
git add vendor/cage2-mini
git commit -m "Update native cage2-mini"
```

Do not update the submodule during an experiment. Its commit is part of the
environment version and should be recorded with results.

## Loading

`cl-tpg.asd` locates and loads `vendor/cage2-mini/cage2-mini.asd` before
defining BES. Loading BES therefore also loads the `cage2-mini` system:

```lisp
(asdf:load-asd #P"/path/to/bes/cl-tpg.asd")
(asdf:load-system "cl-tpg")
(asdf:find-system "cage2-mini")
```

If the submodule is missing, loading stops with a message explaining how to
initialize it. The existing Py4CL2 dependency remains available for official
CybORG, Python cage2-mini, and CAGE3, but native rollouts do not start or call
Python.

## New training

Open the normal BES menu:

```text
M-x tpg-menu
Configure & START
```

Set:

```text
Evaluation Mode: online
Online Environment: Cage2Lisp-b_line-100-v0
Number of Observations: 52
Number of Actions: 11
```

The available training environments are:

- `Cage2Lisp-b_line-100-v0`
- `Cage2Lisp-meander-100-v0`
- `Cage2Lisp-sleep-100-v0`

The environment internally retains all 145 concrete ChallengeWrapper actions.
BES remains configured with 11 terminal targets because the terminal learner's
registers separately choose Analyse, Remove, Restore, or Decoy and the decoy
option.

## Resume training

Choose:

```text
M-x tpg-menu
Resume Search
Evaluation mode: online
Online environment: Cage2Lisp-<selected red agent>-100-v0
Number of observations: 52
Number of actions: 11
```

Use the exact hyphenated environment name shown in the completion menu, for
example `Cage2Lisp-b_line-100-v0`.

Checkpoints store their environment name and fitness protocol. Resuming with
the same native environment replays the saved fitness. Changing from native
Lisp to official/Python CAGE2, or changing the red agent, makes the old fitness
non-comparable; BES keeps the policy but safely re-evaluates and re-baselines
its score.

## Validation

Choose:

```text
M-x tpg-menu
Validate Best Team
Validation environment: cage2-lisp
```

Then select:

- `single-red-full`: 30, 50, and 100 steps, 1000 episodes each;
- `single-red-100`: 100 steps and a user-provided episode count.

Select B-line, Meander, or Sleep in the next prompt. The native validation
environment names are generated internally:

```text
Cage2Lisp-b_line-30-v0
Cage2Lisp-b_line-50-v0
Cage2Lisp-b_line-100-v0
```

Choose `cage2` instead of `cage2-lisp` to run the same protocol through the
official Python CAGE2 path. Final reported results should come from a pinned
official checkout.

## Reproducibility

Every candidate sees the same deterministic episode-seed batch rooted at 153.
The native environment has its own reproducible 64-bit RNG; it intentionally
does not reproduce NumPy or Python random values step-for-step. Consequently:

- same BES commit, cage2-mini submodule commit, settings, and seed are replayable;
- native and Python results should be compared statistically;
- switching backends causes checkpoint fitness to be re-baselined.

## Tests

From the BES repository:

```powershell
sbcl --script vendor/cage2-mini/lisp/run-tests.lisp
sbcl --script tests/native-cage2-integration.lisp
```

The first command tests the environment. The second stubs the BES policy and
Python bridge, then proves that a native rollout translates semantic actions,
runs the requested number of steps, and never calls Python.

# BES/TPG Research Extension

## About

This repository is a research-oriented fork of **cl-tpg**, developed for autonomous cyber defence research.

The objective of this project is to extend the engineering capabilities of the original BES/TPG framework without modifying its evolutionary algorithm whenever possible.

Rather than redesigning BES/TPG, this fork focuses on adding practical functionality required for large-scale experimentation, checkpoint management, validation, Gymnasium integration, and cyber defence research while maintaining compatibility with the upstream project whenever possible.

---

## Original Project

This project is based on the original **cl-tpg** repository:

https://github.com/bmcnns/cl-tpg

Please refer to the original project for:

- Installation instructions
- BES/TPG architecture
- Tangled Program Graph (TPG)
- Evolutionary algorithm
- Team and learner representations
- Instruction set
- Online and offline training workflow

This repository intentionally does **not** duplicate the original documentation.

Readers interested in the BES/TPG algorithm itself are encouraged to consult the original repository, while this README focuses exclusively on the engineering extensions introduced in this fork.

---

# Design Philosophy

One of the primary goals of this fork is to preserve the original BES/TPG implementation as much as possible.

The following components remain unchanged from the upstream implementation whenever possible:

- Team representation
- Learner representation
- Program representation
- Mutation operators
- Selection strategy
- Reproduction strategy
- Migration between islands
- Island model
- Evolutionary search workflow

Instead of modifying the evolutionary algorithm itself, new functionality is implemented around the existing framework as auxiliary engineering components.

This approach minimizes divergence from the upstream repository while allowing new research functionality to be integrated cleanly.

---

# Major Extensions

## 1. Automatic Best-Team Checkpoint

A lightweight checkpoint mechanism has been added.

Features include:

- Configurable checkpoint directory
- Immediate checkpointing whenever a new global best is accepted
- Save only the globally best team

Unlike traditional evolutionary checkpoints, this implementation intentionally does **not** save the entire evolutionary population.

---

## 2. Warm-Start Resume Search

Interrupted searches can be resumed without restoring the original population.

The resume workflow is:

```
Random Population
        │
        ▼
Load Saved Best Team
        │
        ▼
Replace First Root Team
        │
        ▼
Evaluate Initial Population
        │
        ▼
Continue Normal Evolution
```

This design preserves evolutionary diversity while allowing previously discovered high-quality policies to seed future searches.

---

## 3. Validation Framework

Training and validation are treated as two completely independent workflows.

Validation loads a previously saved best team and evaluates it without modifying the evolutionary search.

### CAGE2

Two validation modes are currently supported.

**Mode 1**

Single selected Red agent.

Runs:

- 30 steps × 1000 episodes
- 50 steps × 1000 episodes
- 100 steps × 1000 episodes

Results are reported individually, for example:

```
b_line-30
b_line-50
b_line-100
b_line-total
```

The same workflow applies to:

- RedMeanderAgent
- SleepAgent

**Mode 2**

Single selected Red agent.

Runs:

- 100 steps
- User-defined number of episodes

---

### CAGE3

Two validation modes are currently supported.

**Mode 1**

- 500 steps
- 1000 episodes

**Mode 2**

- 500 steps
- User-defined number of episodes

---

## 4. Python Bridge

Online training and validation require a Gymnasium-compatible Python environment.

Rather than modifying the BES/TPG evolutionary engine, this project uses a lightweight **Gymnasium bridge** that connects the Lisp implementation of BES/TPG with Python environments through the standard Gymnasium API.

The bridge is responsible for:

- Registering custom Gymnasium environments
- Wrapping external simulators
- Providing the standard `reset()` / `step()` interface
- Exposing observation and action spaces to BES/TPG

This design keeps Python environments completely independent from the Lisp implementation while allowing new environments to be integrated without modifying the evolutionary core.

The Gymnasium bridge currently used in this project is available here:

https://github.com/PopcornBoat/custom-gym-for-bes

## 5. Python Interpreter Management

The framework supports switching between multiple Python environments directly from the Emacs interface.

Typical usage:

```
CAGE2 Python Environment

↓

CAGE3 Python Environment
```

Interpreter selection is:

- Persistent across sessions
- Hot-swappable
- Does not require restarting Lisp

This allows multiple CybORG codebases to coexist without compatibility issues.

---

## 6. Improved Emacs Interface

The Emacs frontend has been extended with several new utilities.

Current functionality includes:

- Configure and start training
- Resume search
- Validation
- Save best team
- Configure Python interpreter
- Automatic path completion
- Dashboard improvements

Interactive TAB completion is supported for:

- Dataset files
- Checkpoint directories
- Saved best teams
- Python interpreters

---

## 7. Dashboard Improvements

Additional runtime statistics have been added to the dashboard.

Current information includes:

- Current best fitness
- Rolling mean fitness
- Generation count
- Total evaluation episodes

These statistics simplify long-running evolutionary experiments.

---

## Search failure diagnostics

Dashboard telemetry is best-effort and cannot terminate training. The most
recent UDP/dashboard problem remains available as `*last-telemetry-error*`.
An unhandled search-worker error is preserved in `*last-search-failure*` with
its generation, condition type, message, and pre-unwind backtrace. The same
record is appended to `search-errors.log` in the active checkpoint directory,
so it remains available even when the dashboard cannot receive the report.
Both variables are reset appropriately when a new search begins.

---

## CAGE2 policy observations

The official CAGE2 bridge supplies 142 policy inputs: the original 52-value
observation, ten episode-local scan-history values in target order, and 80
binary decoy-availability values in host-major agreement order. Scan hosts are:
Defender, Enterprise0-2, Op_Server0, and User0-4. `0` means unseen, `1` means
scanned previously, and `2` identifies the most recently detected scan. The
bridge initializes the state to zero, consumes and maintains it throughout one
episode, and clears it at the episode boundary. Availability uses `1` for an
unused option and `0` for a used option. BES receives the completed 142-value
vector and performs no CAGE2-specific online state extraction itself.

Online training, offline collection, and validation must all use the same
scan-state bridge version. Episode and step indices are not included.

---

## Offline semantic imitation

BES accepts the line-oriented `cage2-semantic-v1` datasets produced by the
CAGE2 collector. Start an offline search with the `_train.lisp` file, configure
142 observations and 11 targets. BES expands the 62 values stored in each row
with 80 binary availability values from `:decoy-mask-before`. BES automatically loads the sibling `_val.lisp`
file as the fixed reference dataset. For example,
`cage2_bline_semantic_train.lisp` is paired with
`cage2_bline_semantic_val.lisp`.

Each generation uses one uniform, unbalanced training-row sample shared by all
candidates. Semantic accuracy follows the bridge contract: GLOBAL compares only
the target; host actions compare target and response; Decoy resolves the first
available agreement option and compares it with the teacher option. The
complete held-out file supplies the stable reference fitness used for best-team
selection and checkpoint replay. Online and offline runs use the same
policy-owned table of ten decoy-option permutations. Each table starts from the
agreement defaults, evolves through pair swaps, is installed in the Python
environment once per episode, and is serialized with its team.

Runs require finite learner and program limits. The Emacs defaults use hard
ceilings of 32 learners per team and 256 instructions per program. Growth
pressure begins tapering above soft thresholds of 11 learners and 128
instructions, while every size below the hard ceiling remains reachable.
This controls bloat and GC pressure without equating the 11 targets with the
number of useful learner specializations.

Above each soft threshold, the corresponding addition probability follows an
inverse-square taper. Additions remain possible up to the hard ceiling, but
their expected pressure approaches deletion pressure instead of producing
permanent positive size drift. Exact fitness ties prefer the policy with fewer
instructions, then fewer learners, then fewer reachable teams; a policy with
better fitness is never discarded merely because it is larger. The dashboard
reports population team, learner and instruction counts plus observed maximum
team and program sizes. Warm-starting an older oversized policy emits a warning
and preserves the policy rather than silently pruning it.
Checkpoints record the semantic fitness protocol, dataset file fingerprints,
and the complete action-agreement signature, so a resume against different
files or mappings is re-baselined rather than compared to an incompatible
score. The policy graph itself remains a full serialize/deserialize deep copy.

Legacy atomic-action datasets retain their original loading and accuracy
behavior. Reward-based offline fitness and richer state inputs remain future
work.

## Optional Hamming observation projection

The Emacs main menu has a `Hamming Projection (next operation)` section. Use
`F` to select a semantic `_train.lisp` dataset, then `H` to switch projection
on or off before starting, resuming, or validating. The selected setting and
file are copied into the request, so changing the menu later cannot alter an
active operation. Keep the switch off for the baseline run and turn it on for
the comparison run using the same checkpoint and validation seeds.

With projection enabled, exact demonstrated observations pass through
unchanged. An unseen 142-value CAGE2 observation is replaced only for policy
execution by its nearest unique demonstrated observation; the current Python
environment state is not modified, and the TPG still chooses the action. Ties
are deterministic and retain the first state encountered in the dataset.

Distance is categorical, block-normalized weighted Hamming distance. The raw
52 values contribute 50% of the maximum distance, the ten scan-history values
25%, and the 80 decoy-availability values 25%. This prevents the large
availability block from dominating merely because it has more fields. The
equivalent integer mismatch weights are 40, 104, and 13 respectively.

Offline training uses the selected training file as the reference space, so
training rows normally take the exact fast path while unseen held-out rows are
projected. Online training and CAGE2 validation stream the reference file once
at operation setup and retain only unique observations. Hamming mode and the
reference file fingerprint are recorded in checkpoints; a warm start with a
different setting or reference file is re-baselined instead of comparing
incompatible historical fitness values.

---

# Current Research Status

Current research focuses on applying BES/TPG to autonomous cyber defence using the CAGE benchmark.

Currently implemented components include:

- Online evolutionary training
- Offline imitation learning for legacy atomic and CAGE2 semantic datasets
- Automatic best-team checkpointing
- Warm-start resume search
- Validation framework
- CAGE2 integration
- CAGE3 integration
- Gymnasium bridge
- Multiple Python interpreter support
- Enhanced Emacs interface

Future work includes:

- Reward-based offline fitness
- Controller-based CAGE2 evaluation
- Additional cyber defence environments
- Continued synchronization with upstream **cl-tpg**

---

# Acknowledgements

This project would not exist without the excellent work of the original **cl-tpg** authors.

All credit for the BES/TPG framework belongs to the original project.

This repository only extends the framework with additional engineering functionality required for my research while attempting to preserve the original implementation and remain compatible with future upstream development whenever possible.

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
- Stable configuration-derived filenames

Automatic and menu-requested saves include the agent, policy shape, training
mode, Decoy-order mode, episode-opening mode, Hamming state, and policy-memory
mode. For example,
a b-line policy can be saved as
`bline-62-11-online-order-fixed-opening-fixed-hamming-off-memory-recurrent.lisp`.
B-line and meander are inferred from the active environment or dataset;
unrecognized tasks use `agent`. Each configuration overwrites only its own
immediate-best file, so online/offline and Hamming ON/OFF variants can coexist
in one checkpoint directory. Historical `best-team.lisp` files remain valid
for loading and warm starts.

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

File prompts are controller/target aware. TAB completes files that are visible
to the Emacs controller, while paths that exist only on a remote island may be
typed and submitted without a false local `must exist` rejection. Home-relative
paths remain in `~/...` form so macOS does not rewrite them to `/Users/...`
before sending them to a Linux island. If the suggested directory does not
exist locally, completion starts at its nearest existing parent instead of
failing when the prompt opens.

---

## 7. Dashboard Improvements

Additional runtime statistics have been added to the dashboard.

Current information includes:

- Current best fitness
- Rolling mean fitness
- Generation count
- Total evaluation episodes
- Wall-clock elapsed search time (HH:MM:SS)

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

The official CAGE2 bridge always transports 142 values: the original 52-value
observation, ten episode-local scan-history values in target order, and 80
binary decoy-availability values in host-major agreement order. BES's existing
`Number of Observations` setting selects the policy prefix. The active baseline
is `62`: raw plus scan state, with concrete Decoy availability owned by the
bridge. The former `142` experiment exposes the complete observation and is
retained only as an archived/legacy compatibility mode for existing datasets
and checkpoints. New start, resume, and validation menus default to `62`.
Scan hosts are:
Defender, Enterprise0-2, Op_Server0, and User0-4. `0` means unseen, `1` means
scanned previously, and `2` identifies the most recently detected scan. The
bridge initializes the state to zero, consumes and maintains it throughout one
episode, and clears it at the episode boundary. Availability uses `1` for an
unused option and `0` for a used option. The bridge remains the authoritative
owner of this episode-local state in both modes; 62-input BES programs simply
cannot address the availability suffix.

Online training, offline collection, and validation must all use the same
scan-state bridge version. Episode and step indices are not included.

---

## Ranked semantic imitation and next-best execution

BES accepts both line-oriented `cage2-semantic-v1` datasets and ranked
`cage2-semantic-v2` datasets produced by the CAGE2 collector. Start an offline
search with the `_train.lisp` file, configure
62 observations and 11 targets for new experiments. The source dataset remains
reusable in legacy 142 mode:
modes: BES reads its stored 62 values directly in 62 mode or appends 80 binary
availability values from `:decoy-mask-before` in 142 mode. BES automatically loads the sibling `_val.lisp`
file as the fixed reference dataset. For example,
`cage2_bline_semantic_train.lisp` is paired with
`cage2_bline_semantic_val.lisp`.

For v2, every row retains its historical concrete semantic triple and adds a
frequency-ranked list of `(target response)` alternatives for that exact
62-value observation. Concrete Decoy options are not supervised. The ranked
fitness is `0.8 * executable-action accuracy + 0.2 * ranking NDCG`: availability
from `:decoy-mask-before` resolves the first usable prediction, while NDCG
rewards agreement with the teacher's full frequency order. The complete v2
training and validation files must both use the ranked format; BES rejects a
mixed v1/v2 pair.

At execution time BES emits up to eight unique semantic candidates in
hierarchical bid order. The first candidate is exactly the existing TPG winner:
the highest-bidding learner is followed recursively until a terminal learner is
reached. Alternatives are then explored depth-first by descending local bid,
and every terminal candidate uses that learner's own saved registers. The
bridge consumes this list once. If the selected host has no unused Decoy it
tries the next candidate, skips Restore while in fallback mode like the fixed
teacher, and finally uses Monitor if nothing is executable. This avoids a
second Lisp/Python call. Historical single-action bridge input and v1 dataset
fitness remain supported.

## Teacher forcing

Teacher forcing is a third search mode for CAGE2 tasks. `Teacher Backend`
selects a packaged local ranked teacher. `model` preserves the existing frozen
model teachers for b-line and meander. `heuristic` selects the deterministic
BlueBLineHeuristicSimple-compatible b-line teacher. Its label query is pure:
scan history and used-Decoy state are read from the current 142-value bridge
observation, so querying a learner-visited state cannot advance teacher state.
The TPG still receives only the configured 62-value prefix.

The heuristic backend expands the original concrete action into a stable
ranking: applicable Analyse/Restore rules first, available Decoy targets in the
heuristic's global order next, then its former fallback action list in fixed
order, and finally Monitor. The original random fallback is not used. Its
teacher-specific per-host Decoy profile is loaded from the shared action
agreement, ensuring `(target, DECOY)` executes the same concrete option intended
by the heuristic. Backend/profile identity is stored in checkpoint metadata and
filenames.

The default `dagger` rollout lets the current best TPG policy control a second
copy of each episode after the fixed opening. The selected teacher sees those
exact learner-visited observations and supplies ranked semantic labels, but
never acts in or changes that environment. The menu's `teacher` rollout
preserves teacher-controlled behavior cloning.

For the model backend, teacher forcing supports b-line and meander. The current
heuristic backend is intentionally b-line-only.

Once per generation, the bridge generates the configured number of teacher
episodes from a seed list shared by the complete population. In `dagger` mode,
BES also runs the current behavior team on those seeds, appends its labelled
states to a bounded replay retaining the newest 10,000 rows, and samples one
replay row per current teacher row. The resulting fitness set is therefore a
50/50 teacher/replay mixture once enough replay exists. BES scores every team
on exactly the same rows using the ranked offline objective:
`0.8 * resolved behavior accuracy + 0.2 * ranking NDCG`. Evolution then uses
the normal selection, cloning, mutation, and replacement path. Simulator cost
therefore scales with two rollout banks per generation in `dagger` mode,
rather than population size multiplied by fitness episodes.

Replay observations are stored as compact double-float arrays instead of
boxed lists. DAgger also requests a full SBCL collection every 25 generations
after the previous fitness dataset is released, preventing retired trace rows
from accumulating in older heap generations during long searches. For long
CAGE2 runs, start SBCL with `--dynamic-space-size 4096` or larger.

Historical-best comparison deliberately remains a fixed 100-episode
teacher-controlled reference bank derived from seed 153 and generated once
when the search starts. It is stable and replayable, while online validation
remains the final measure of closed-loop behavior. Teacher
forcing requires 11 targets, 62 policy observations for the active baseline
(legacy 142 remains accepted), and fixed
Decoy ordering. No dataset fingerprint is involved. A warm start is comparable
only when its teacher-forcing protocol, environment, observation prefix,
fitness-episode count, episode-opening mode, rollout mode, teacher backend,
Hamming configuration, and action agreement match. `dagger` and `teacher` use
different checkpoint filenames and fitness protocol tags, so changing modes
safely re-baselines a warm start.

## CAGE2 episode opening

The start, resume, and validation menus expose `Episode Opening` with two
modes. `fixed` is the recommended main-agent protocol: the episode controller
executes `User2 Decoy`, `User2 Decoy`, and `Enterprise0 Decoy` during steps
0-2, then TPG begins acting at step 3. These probes exist to expose the red
policy; the fourth observation is the first policy decision state. Fixed Decoy
ordering resolves the repeated User2 semantic action to successive concrete
Decoys without another TPG call.

In teacher-controlled rollout mode the teacher still executes the complete
episode, but the first three rows are excluded from TPG fitness when `fixed`
opening is selected. In DAgger rollout mode, the controller executes those
steps while both teacher and TPG observe the same state; the teacher advances
its opening position and TPG begins controlling and contributing rows at step
3. Online search and validation use the same controller sequence. `policy`
disables the controller and restores the older behavior in which TPG acts from
step 0.
Opening mode is part of checkpoint filenames and metadata; checkpoints created
before this protocol are treated as `policy` opening and re-baselined when
resumed under `fixed`.

## Optional recurrent learner registers

The Emacs main menu exposes `Recurrent Registers (next operation)`. When it is
enabled for CAGE2 online search or validation, every learner owns an independent
eight-register vector for the duration of one environment episode. All learners
still execute and bid normally; a learner sees the register values left by its
own previous executions, never values from another learner. The complete bank
is discarded at environment reset, so every episode starts from zero. With the
switch off, each bid retains the original behavior and starts from zero.

The fixed three-step opening does not execute TPG programs. Recurrent state
therefore remains zero during those controller-owned steps and begins evolving
when TPG first acts at step 3. Internal team traversal is unchanged: each
visited team's learners bid, team-reference winners continue traversal, and the
final terminal learner supplies the semantic action.

Recurrent mode is available consistently across semantic offline,
teacher-forcing, online CAGE2 search, and CAGE2 validation. The two menu controls
compose as follows:

| Search mode | Recurrent registers | Teacher rollout | Result |
|---|---|---|---|
| offline | off | ignored | stateless offline imitation |
| offline | on | ignored | recurrent behavior cloning from the selected file |
| teacher-forcing | on | teacher | recurrent behavior cloning from fresh teacher episodes |
| teacher-forcing | on | dagger | recurrent DAgger |
| online | on | ignored | recurrent reward optimization |

Recurrent offline loading requires ranked semantic rows with `:episode-id` and
`:step`. BES validates that each episode is adjacent and step-complete, then
samples whole episodes instead of unrelated rows. `Batch Size` remains an
approximate transition budget: the final complete episode may take the batch
slightly over that number. All population candidates receive the same sampled
episodes. Registers start at zero for each episode and persist only while its
rows are evaluated in order.

Under the fixed opening protocol, offline rows at steps 0--2 neither execute
TPG programs nor contribute fitness. This matches online execution, where the
controller owns those probes and recurrent TPG state first changes at step 3.
The existing ranked-v2 collector files already contain the required episode
metadata; older row-only datasets remain usable only with recurrent mode off.

Teacher-forcing traces now preserve episode and step metadata. In recurrent
DAgger, the behavior team is wrapped in a fresh register bank for each actual
environment episode, and replay stores/samples complete episodes rather than
isolated rows. Teacher-controlled and learner-controlled episodes are scored
with the same sequence-aware ranked objective. Stateless teacher-forcing keeps
the previous row-wise replay and fitness behavior.

Register state is runtime-only and is not serialized. The policy graph and
programs keep their existing checkpoint representation, while checkpoint
metadata and filenames record `memory-recurrent` or `memory-stateless`.
Recurrent offline, recurrent teacher-cloning, recurrent DAgger, and stateless
imitation use distinct fitness protocol tags, so saved fitness values are never
compared across incompatible objectives. Independent staged online evaluators
receive the same setting as the search. Legacy checkpoints are interpreted as
stateless.

The recommended capability run is 62 observations, 11 targets, fixed
Decoy order, Hamming projection off, five fitness episodes, population 160,
and a fresh search. Batch size is not used in this mode. B-line and meander
must be trained separately. The model backend loads packaged NumPy teacher
artifacts, while the heuristic backend contains only deterministic policy logic;
neither requires the original training framework.

Each generation uses one uniform, unbalanced training-row sample shared by all
candidates. Semantic accuracy follows the bridge contract: GLOBAL compares only
the target; host actions compare target and response; Decoy resolves the first
available agreement option and compares it with the teacher option. The
complete held-out file supplies the stable reference fitness used for best-team
selection and checkpoint replay. Online and offline runs use the same table of
ten decoy-option permutations. Choose `fixed` Decoy order to always use the
teacher-derived agreement defaults and disable order mutation, or `evolved` to
start from those defaults and evolve pair swaps. The effective table is
installed in the Python environment once per episode. Team tables remain
serialized in checkpoints, while fixed mode deliberately ignores their values.

The completed 62/142 and fixed/evolved comparison is archived as prior
experimental history. New work uses 62/fixed unless a legacy checkpoint is
being reproduced. BES continues to accept 142 and evolved-order runs so those
artifacts remain loadable, but the menus no longer present them as the primary
path.

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
Checkpoints record the semantic fitness protocol, observation prefix, Decoy
order mode, dataset file fingerprints, and the complete action-agreement
signature, so a resume against different files or mappings is re-baselined
rather than compared to an incompatible score. Their filenames include
`order-fixed` or `order-evolved`. The policy graph itself remains a full
serialize/deserialize deep copy.

Legacy atomic-action datasets retain their original loading and accuracy
behavior. Reward-based offline fitness and richer state inputs remain future
work.

## Protected mixed online fine-tuning

Warm-starting CAGE2 online search from a semantic-offline or teacher-forcing
checkpoint marks the lineage as mix. Its immediate-best filename therefore
uses mix instead of online, while the source checkpoint remains untouched.
The lineage is stored in checkpoint metadata and survives later resumes.

When online search is launched with five fitness episodes, BES automatically
uses a 5 -> 10 -> 20 curriculum: five episodes through generation 200, ten
from generation 201 through 500, and twenty from generation 501 onward. All
population candidates still share one newly generated seed bank per generation.
Launching with any other episode count keeps that count fixed for controlled
comparisons.

Historical-best promotion is deliberately more conservative than population
selection. Online search accumulates the strongest generation-training winner
over ten generations, serializes a frozen copy, and submits it to a separate
SBCL evaluator process. The search thread never waits for this reference job and
continues population selection using the current curriculum seed bank.

The evaluator first compares the candidate and frozen incumbent on the first 20
episodes of the fixed 100-episode seed bank rooted at 153. A clearly futile
candidate (paired mean plus one standard error no better than zero) is rejected
without spending the remaining rollouts. Every uncertain or promising candidate
continues through all 100 paired episodes. It replaces the historical best only
when its complete paired mean improvement exceeds one standard error, exactly as
under the earlier robust promotion guard. The main search process alone consumes
the result, updates its in-memory historical best, and writes the public
checkpoint; the worker cannot race the search by overwriting it directly.

Candidate requests, results, and worker logs are stored under
`.online-candidates/` in the selected checkpoint directory. A result whose
incumbent no longer matches the in-memory incumbent is discarded as stale.
This design prevents lucky training episodes from replacing a strong warm-start
policy while moving expensive reference evaluation off the evolutionary loop.

## Optional Hamming observation projection

The Emacs main menu has a `Hamming Projection (next operation)` section. Use
`F` to select a semantic `_train.lisp` dataset, then `H` to switch projection
on or off before starting, resuming, or validating. The selected setting and
file are copied into the request, so changing the menu later cannot alter an
active operation. Keep the switch off for the baseline run and turn it on for
the comparison run using the same checkpoint and validation seeds.

With projection enabled, exact demonstrated observations pass through
unchanged. An unseen configured 62- or 142-value CAGE2 policy observation is replaced only for policy
execution by its nearest unique demonstrated observation; the current Python
environment state is not modified, and the TPG still chooses the action. Ties
are deterministic and retain the first state encountered in the dataset.

Distance is categorical weighted Hamming distance. Raw and scan mismatch
weights are identical across modes. In 142 mode the availability block retains
its existing normalized contribution; in 62 mode it is absent from both the
prototype and distance calculation.

Offline training uses the selected training file as the reference space, so
training rows normally take the exact fast path while unseen held-out rows are
projected. Online training and CAGE2 validation stream the reference file once
at operation setup and retain only unique observations. Hamming mode and the
reference file fingerprint are recorded in checkpoints; a warm start with a
different setting or reference file is re-baselined instead of comparing
incompatible historical fitness values.

Hamming-enabled CAGE2 validation also reports exact reference coverage after
the rollouts finish: total policy lookups, exact hits, total misses, distinct
missed observations, and miss percentage. A miss means the selected live
62- or 142-value policy observation was absent from the reference dataset before nearest-state
projection. Counters are disabled during training and reset for every
validation. The latest summary is also available as
`*last-hamming-validation-coverage*` in the `CL-TPG` package. Exact coverage is
measured in the selected policy space, so 62- and 142-input miss rates are not
directly comparable as counts of the same state identity.

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

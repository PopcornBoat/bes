# Controller-aligned repair credit

This bounded experiment follows the multi-seed privileged search on
`online-privileged-search`. It does not change the production training loop,
historical-best promotion, Controller scheduler, or the policy input.

## Problem and measurement contract

A nominal Semantic-36 terminal is not necessarily the concrete action executed
when its learner joins a full ranked policy. The Controller can select a
different Decoy host from its fixed global schedule. Credit for a single-pair
intervention must therefore not be assigned directly to the compiled child's
terminal.

The pilot accepts either the legacy single-pair intervention or a complete
semantic ranking. For a ranking intervention it:

1. Restores the same environment seed and verifies the frozen prefix, including
   the simulator digest, 62 inputs, Controller state, ranking and active path.
2. Resolves the entire alternative ranking with the normal Controller.
3. Requires the resolved concrete action to equal the expected action and the
   bridge's actually executed action.
4. Executes that action once, then resumes the frozen continuation policy.

Evidence keys include parent/continuation/environment identity, seed, concrete
prefix, branch-point simulator digest, Controller state, 62 inputs and actual
concrete action. Unchanged actions have zero intervention difference. Unmeasured
actions remain unknown; they are not zero-valued observations.

The existing brute search retains its single-pair gate score as
`nomination-evidence` and adds a separate `controller-aligned-evidence` report.
The latter only uses measured concrete effects or verified unchanged actions.

## Frozen refinement protocol

Inputs are v9 and candidate 13 from the previous discovery, verified against
the subsequent 50-seed screening manifest. The launcher freezes independent
copies, SHA-256 hashes of source code and simulator/bridge code, trace hashes,
configuration and discovery seed lists.

This is deliberately a refinement of a selected User2 Restore repair, not a
blind action-discovery experiment. No teacher or compiled heuristic is used.

- At most 24 branch points: nominate the first empty-host Restore and first
  intervention from a winning C13 episode, at most one of each per seed.
  Hidden state and episode wins are nomination hints, not correctness labels.
- Replay C13 and verify its stored trace. On that same C13 state, measure its
  decision against the complete v9 ranking, then continue with C13.
- `keep-advantage = original C13 return - alternative return`. This measures
  a one-step intervention under a frozen continuation, not a new policy's value.
- Enumerate equality gates of one or two current observation features using
  the existing read-only categorical constants. All indices are within 0..61.
- A gate's local proxy is zero where it retains C13's original action and
  minus keep-advantage where it suppresses that action. Average within seed,
  then across seeds. Require useful retained cases on at least two distinct
  seeds and proxy mean minus SE greater than zero. These are nomination
  heuristics, not statistical proof; missing eligible gates is a valid result.
- Report conflicting measured signs at identical 62-input observations.
  Such conflicts can reflect hidden state, Controller context, episode phase
  or stochastic variation. They alone do not prove representation insufficiency.
- Refine only the original added learner in independently serialized copies of
  C13. Try margins 250 and 1000; do not stack another specialist or alter the
  rest of the graph. Keep at most 12 distinct concrete-action variants on the
  measured cases.
- Resolve each full child's ranking on each measured context. Supplement
  unknown concrete effects with at most 24 additional official interventions;
  all remaining unknowns are explicitly counted.
- Evaluate complete standalone variants against original v9 on the union of
  the seven original discovery seeds and measured-case seeds. Require paired
  Op_Server0 loss, controlled duration and maximum control streak not to worsen
  on any evaluated seed. Reload each checkpoint and reproduce all returns.
- Positive discovery mean plus the protected-host check can nominate a
  discovery winner. It is not historical promotion. The existing 50 screening
  seeds are now discovery data; subsequent confirmation needs fresh seeds.

History and hidden state never become runtime features. Policies remain
stateless 62-input Semantic-36 TPG graphs with the normal fixed Decoy Controller.

## Run and observe

From WSL:

```sh
cd /home/hardison/bes
scripts/bes-test tests/privileged-search.lisp
scripts/run-controller-aligned-repair /home/hardison/bes-artifacts/runtime/controller-aligned-repair-20261107/search
```

Defaults: 24 cases, 12 variants, 24 supplemental intervention queries. Each
query and complete policy rollout can consume up to 100 official transitions;
this is not a 24-episode total budget. `completed-rollouts.sexp` records
seed, return and transition counts. Full discovery traces and intervention
branches are stored separately; variant result files contain full-policy
returns and protected-host evidence. Whole-policy variants are
evaluated and reloaded on the same fixed discovery seed set.

The Python launcher locks one output directory and rejects changed inputs or
configuration. A completed identical run exits without new rollouts. Completed
intervention files can be reused after interruption; baseline and complete
candidate rollouts may repeat. This is not full search-state restoration.

Artifacts:

- `manifest.json`, `inputs/`, `request.sexp`: frozen experiment identity.
- `nominations.sexp`, `cases.sexp`, `interventions/`: measured branch effects.
- `observation-conflicts.sexp`: equal-input cases with opposing measured signs.
- `gate-diagnostics.sexp`, `gate-ranking.sexp`: accepted and rejected gate summary.
- `variants.sexp`, `aligned-variants.sexp`: standalone candidates and actual-action
  effect evidence, including unknown counts.
- `refined-N.lisp`, `refined-N-result.sexp`: independent policies and paired
  full-episode discovery results.
- `summary.sexp`, `report.txt`: discovery result; the worker prints `done`.

## Engineering verification

The focused suite checks Controller-induced concrete action changes,
context-isolated evidence, unknown versus zero credit, seed-level statistics,
signed gate refinement, equal-input conflicting effects and deep-copy isolation.
An official eight-case smoke run reproduced each prefix and measured both
positive and negative keep-advantages. It found no eligible gate: six cases
shared identical policy inputs despite opposing effects; all 2,198 enumerated
gates had nonpositive eligibility scores. No thresholds were changed to force
a candidate. A separate integration fixture supplied the existing C13 gate to exercise the
otherwise unvisited candidate path. Its standalone graph was evaluated, saved,
reloaded and reproduced its returns; its measured paired result was negative.
This fixture is an accounting/serialization check, not a gate-search success.
The larger run remains an experiment, not a demonstrated repair.

## Stratified dual-trajectory protocol (v2)

The v1 experiment completed with 17 measured points, no eligible gate and no
new candidate. The implementation now samples all actual C13/v9 disagreements,
not just empty-host Restores and winning episodes. Existing v1 artifacts remain
unchanged.

With `--fresh-episodes N`, collect N paired official C13/v9 episodes on a frozen
new seed block. Generation excludes the old screening block, evaluation seeds
and monitoring roots 153/42/2026. These new episodes are discovery data.

Inspect both policies' own trajectories. At a C13 branch point execute the full
v9 ranking once, then continue C13. At a v9 branch point execute the full C13
ranking once, then continue v9. In both cases keep-advantage means C13's local
action minus v9's local action, under the explicitly recorded continuation.
These two continuation estimands are nomination evidence, not interchangeable
estimates of full-policy value. Actual child effects are normalized relative
to the measured local C13 action before being compared.

Select points round-robin across diagnostic strata: current 62-input
observation, active terminal team, concrete action pair, both relevant hosts'
actual Red access levels, trajectory source and 25-step phase. Prioritize
independent seeds and allow at most two points per seed across both sources.
This is a balanced diagnostic sample, not a frequency-representative sample.
Report all available and selected source/access/observation counts. Hidden
state and episode phase remain training-only sampling fields; runtime gates
still use only existing current-observation equality predicates.

The gate family, score threshold, two-positive-seed requirement, protected-host
checks and standalone-policy evaluation are unchanged. If no gate qualifies,
skip the unnecessary whole-candidate baseline batch. A negative result is
retained rather than lowering a threshold to manufacture a candidate.

Example bounded expansion:

```sh
scripts/run-controller-aligned-repair /home/hardison/bes-artifacts/runtime/stratified-controller-repair-20261107/search --fresh-episodes 64 --discovery-seed-root 291107 --max-cases 96 --max-candidates 12 --extra-queries 24
```

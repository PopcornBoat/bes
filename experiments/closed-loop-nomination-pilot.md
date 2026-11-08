# Closed-loop nomination pilot

A standalone, teacher-free comparison of three nomination methods. No production
evolution lane, long population training, C13 refinement or historical promotion.

## Fixed inputs and shared generator

Use frozen original Meander v9 and its 64 genuine official incumbent traces
from the stratified Controller experiment. C13 trajectories and hidden fields
are excluded from nomination. Original collection cost is already paid, not
claimed to be zero. Policies remain stateless 62-input Semantic-36 with the
existing fixed opening and Meander Decoy Controller.

Group by exact observation, terminal and active path. Require two independent
seed exposures; retain the 24 highest-exposure groups. Per group, a frozen
generator chooses two globally varying categorical features for an equality-AND
gate. Every action uses that same gate, margin 250 and terminal insertion.
Only actions feasible in the shared probe Controller context and different
from its incumbent concrete action enter the catalog.

Freeze IDs, group provenance, team, action, gate, margin and generator coordinates
before official offspring evaluation. Deduplicate identical construction recipes.
A frozen parent + generator + recipe defines each complete child. Selected
children are materialized once, serialized, hashed and reloaded, rather than
duplicating every 5MB graph. Overlapping lanes reuse the identical child.

## Three nomination methods

A: coverage score = log(1 + independent seeds) times the mean of direct terminal
absence, Top-8 absence fraction and execution absence fraction.

B: A score times (1 + mean persistence). During negative-reward steps,
persistence = min(5, max(unchanged-observation run, repeated-actual-action run)
- 1) / 5. This is a hypothesis signal, not causal credit.

C: uniform random selection from the same catalog. A/B equal-score ties use a
frozen random permutation. Deduplicated recipes retain maximum originating-group
scores and all group IDs.

Each lane nominates four distinct IDs. Cross-lane overlap is retained and
reported. Only validity, serialization consistency and at least one actual
concrete-action change on the common archive can block official testing.
Inactive nominations stay in the funnel; no replacement after seeing returns.
No single-step counterfactual, teacher label or positive proxy is required.

## Fixed five-episode negative filter

All active unique children and one shared parent baseline run the same five
fresh full Meander-100 episodes. Reject only:

- Any paired Op_Server0 loss, control-duration or maximum-streak regression.
- With at least five episodes, mean paired delta + 2 * sample SE < -10.

The latter is a practical severe-regression rule, not a calibrated test.
Ordinary negative means and uncertainty survive.

Before returns exist, freeze an independent uniform confirmation lottery over
each lane's four IDs. Confirm its first surviving active candidate, not the
highest five-episode mean. No surviving candidate means no confirmation.

## Fresh confirmation and funnel

At most one child per lane runs 20 new shared paired seeds. Parent baseline is
evaluated once per seed; cross-lane duplicate candidates reuse results.

Separate positive mean from exploratory positive evidence:
20 episodes, mean delta - 2.093 * sample SE > 0, and no protected-host regression.
This unadjusted paired t-style criterion is descriptive exploratory evidence,
not multiplicity-corrected proof or historical promotion. Preserve distributions,
paired deltas, tails and violations.

Report nomination -> executable -> archive-active -> closed-loop-active ->
fresh-tested -> fresh-positive. Untested children are unknown. Promotion
attempted=false; promotions=0. Four proposals per lane cannot establish
method superiority.

Nominal upper budget:
(12 + 1) * 5 * 100 + (3 + 1) * 20 * 100 = 14,500 transitions.
This excludes separate engineering smoke. Overlap, inactivity, rejection or
early termination can reduce actual cost. Per-lane attributed costs may overlap;
the global official journal deduplicates actual evaluations.

Start and completion journals track episodes. A started-but-unfinished rollout
blocks automatic retry because its partial transition cost is unknown.
The launcher locks output, freezes source/trace/code/environment hashes and
disjoint seed blocks, rejects changed inputs, and skips completed identical runs.

## Run

```sh
cd /home/hardison/bes
scripts/bes-test tests/closed-loop-nomination-pilot.lisp
scripts/run-closed-loop-nomination-pilot /home/hardison/bes-artifacts/runtime/closed-loop-nomination-pilot-20261108/search
```

Use `--smoke` with separate output and seed/generator roots for one candidate
per lane and one episode per stage; smoke return is not research evidence.

Outputs: `manifest.json`, `catalog.sexp`, `built.sexp`,
`official-journal.sexp`, `rollout-starts.sexp`, `screen-results.sexp`,
`confirmation-choices.sexp`, `confirmation-results.sexp`, `summary.sexp`,
`report.txt` and standalone `offspring/` checkpoints.

# Active specialist incubation: first implementation contract

This branch develops a teacher-free, official-reward-guided candidate lane.
The first milestone separates discovery from value measurement. It does not
hardcode any host/action repair into selection.

## Discovery

The official incumbent audit records the final winning learner, terminal
path, bid margin, selected Semantic-36 action, 62-value policy observation,
Controller feasibility, direct/reachable action support and Top-8 support.
State groups use `(terminal team, full active path, target, four host bits)`.
Each of the following independent lanes nominates its highest-scoring
eligible group; duplicate groups are kept once:

- missing support: feasible response absent from the active path closure;
- suppressed action: directly present response absent from Top-8;
- winner domination: one learner wins a large share of decisions in the
  incumbent and dominates this group;
- persistent behavior: long uninterrupted streak of one action;
- temporal mismatch hypothesis: the same dominant action is used in both
  early and late halves of an episode;
- overactive winner hypothesis: one learner wins this group repeatedly by
  a wide bid margin;
- a same-target, closest-exposure random control for each nominated group.

These are *hypothesis sources*, not reward estimates. No lane uses the
immediate-reward loss-lift multiplication from the first audit. Eligibility
requires 10 independent episode exposures, 20 state rows and at least one
response Controller-feasible in 25% of rows. Lane scores never share one
aggregate scalar. Per-lane capacity is one in the first run, producing at
most twelve groups.

## Official response screen

For each frozen group and fresh seed, use the first matching incumbent state
at step >=3, regardless of response availability or reward. Test all four
Semantic-36 responses that the Controller can execute. Replayed branches
must verify the entire pre-action state and transition prefix. Keep the
first 40 matching seed episodes per group; the first 20 are discovery, the
next 20 confirmation. Incomplete groups remain visible but cannot pass
confirmation. An action is screen-positive only with >=15 available and
>=15 positive confirmation episodes plus positive mean return. This
screen is a prioritization signal; an action requiring repeated execution
may still be explored in a bounded diversity lane despite weak one-step
evidence.

The Meander User2 Restore count is an **analysis-only soft metric**. No
nomination score, action choice, candidate acceptance or promotion threshold
may read its target or response IDs. Later candidate reports must separately
measure whether the standalone TPG graph contains, selects and actually
executes that repair on official trajectories.

## Candidate incubation and promotion

`scripts/synthesize-opportunity-candidates.py` selects at most four response
hypotheses after the screen. Categorical one- or two-feature gates are fitted
only on the discovery states, with separate incumbent audit observations used
for collateral checks. Each hypothesis may create a terminal insertion with
bid 1000, a root insertion with bid 250, and a two-feature terminal variant.
The selection code does not read the Meander User2 Restore metric.

`active-specialist-incubation.lisp` copies the entire incumbent graph by the
existing serialize/deserialize route, inserts one ordinary TPG learner with a
Semantic-36 terminal, and rejects candidates that do not change the chosen
probe or change more than half the sampled background decisions. Generated
graphs remain normal checkpoint files and retain the source execution profile.

`scripts/run-specialist-incubation` builds candidates and submits the accepted
ones to the existing official admission evaluator. Two fresh paired episodes
serve as a negative filter, followed by a common-seed tournament at
5/12/40/100 episodes with up to four independent policy workers. Discovery,
response-screen, admission and post-selection action-audit seed blocks are
disjoint. The request hashes the incumbent and candidate checkpoints; each
result is an immutable file under the run directory. The standalone admission
winner is **not** a promoted historical
best; fresh staged promotion remains necessary before replacing an incumbent.

If a tournament winner exists, the runner compares it with the incumbent on
the same 20 fresh official seeds and writes `user2-restore-soft-metric.json`.
This is analysis only: it reports actual selected User2 Restore actions and
episode returns, not a training gate. A result of zero means this run has not
shown that the behavior was learned.

The winner is then fixed and compared alone against the incumbent on another
100 fresh paired seeds. A nonpositive result cannot be imported, even if the
first tournament selected it. This confirmation request and result are kept
separately from the multi-candidate tournament.

Example command after the response screen has finished:

```bash
bash scripts/run-specialist-incubation \
  validated-checkpoints/meander-v8/meander-62-36-v8.lisp \
  Cage2-meander-100-v0 \
  /home/hardison/bes-artifacts/validations/meander-opportunity-screen-20261029 \
  /home/hardison/bes-artifacts/validations/meander-opportunity-discovery-20261029 \
  20000000 \
  /home/hardison/bes-artifacts/validations/meander-specialist-incubation-20261029
```

The `INCUBATION_BUILD_ONLY=1` environment variable stops after candidate
checkpoints and the admission request are prepared. No generated descendant
is inserted into a live population solely because it passed a local probe.

To import an admission result into a live population, start an official-guided
warm start from the *exact incumbent checkpoint named in the request* with
`*official-admission-enabled*` true and set
`*incubation-admission-import-request*` and
`*incubation-confirmation-request*` to their absolute request paths before
calling the warm-start function. Startup checks source and candidate hashes,
environment, action contract and disjoint seed lists. Only a positive
independent 100-episode confirmation can install bounded evidence anchors and
queue the fixed winner for ordinary fresh-seed Stage-4 promotion. No
historical best file is overwritten on import. A different or changed
incumbent is rejected.

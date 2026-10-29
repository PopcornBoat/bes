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

Screened hypotheses are to produce multiple legal TPG descendants with
different categorical gates, bid margins and insertion locations. A frozen
incumbent graph is copied with serialize/deserialize before variation.
Incubation may use cheap behavioral probes and limited parallel official
workers. An incubated descendant receives bounded population/lineage
opportunity only after independent official evidence. Historical best may
change only through the existing fresh-seed staged promotion and deep-copy
checkpoint path. Workers own separate environment, Controller and RNG state;
they write independent result files. Record official transitions per
confirmed improvement and lane provenance.

# Structural opportunity audit: frozen Level 1 protocol

## Research question

Can the incumbent TPG graph and its own official rollouts nominate state/path/action opportunities more efficiently than an equally eligible random nomination? Level 1 ranks opportunities only. It does not evaluate action substitutions or create a learner.

This protocol was frozen before the new rollout and ranking were inspected. The known Meander User2 Restore repair is a positive control, not independent evidence of generality.

## Fixed inputs

- Frozen parent: /home/hardison/bes-artifacts/validations/meander-bid-guidance-gen463-20261026/checkpoints/bid-guidance-gen463.lisp
- Official environment: Cage2-meander-100-v0
- 100 distinct discovery seeds: 11000000 + 197*i, i=0..99
- 62 input values; stateless policy; fixed opening and fixed Meander heuristic Decoy order
- All 36 entries of the existing Semantic-36 catalogue receive the same algorithm.
- No teacher proposal, known User2 repair file, or official action intervention enters nomination.

## State groups and action eligibility

The active path is represented for grouping by its final terminal team. The complete preferred path is retained in raw records. For every learned host target, form a group from (terminal team, target, exact four-value host observation tuple). This is a symmetric CAGE2 observation-schema projection for targets 1,2,3,4,5,7,8,9,10, whose raw tuple offsets are respectively 0,4,8,12,28,36,40,44,48. It does not single out any host or response. Each group has four candidate responses for its target. Full 62-value observations remain in the raw audit. A Controller Monitor fallback is recorded with executed action index -1 and never counted as a Semantic-36 execution.

An opportunity is rank-eligible only when its group and its within-terminal target complement each appear in at least 10 independent episodes and the candidate resolves to the requested Semantic-36 pair in at least 10 independent episodes. Ineligible rows remain in the complete table with their reason.

## Frozen nomination score

For each (group, action), compute:

- exposure = independent episodes containing the group / 100;
- persistence = mean longest consecutive run of the group per exposed episode / 100;
- loss lift = max(0, mean per-episode negative immediate reward in the group minus the mean for the same terminal and target outside this exact tuple);
- direct support rate = fraction of group steps whose active terminal has a direct atomic learner with this pair;
- Top-8 rate = fraction of group steps whose ranked alternatives contain this pair;
- execution rate = fraction of group steps executing this pair;
- feasibility rate = fraction of group steps for which the pure Controller resolver returns this pair without fallback.

support deficit = 1 - (0.50*direct support rate + 0.25*Top-8 rate + 0.25*execution rate).

score = exposure * persistence * loss lift * support deficit * feasibility rate.

The observed rollout reward enters only as an adverse-state association. No alternate-action return, teacher label, hidden simulator state, or future outcome of a candidate action enters this score. This score is a nomination heuristic, never an estimated advantage. Episode-level aggregation avoids treating successive steps as independent episodes.

Rows are sorted by descending exact score. Exact ties share a rank interval. A Semantic-36 action receives the maximum eligible group score for that action; its rank interval among all 36 actions is reported. User2 Restore qualifies as unambiguous Top-5 only if the upper end of that interval is at most 5. No tie-breaking may be chosen after seeing results.

## Structural interpretation

Raw records separately include direct terminal support, support reachable through that terminal's team references, Top-8 presence, actual execution, Controller feasibility, bid margin, and full preferred path. Missing support, suppressed bid/routing, and Controller unavailable are reported separately. Structural absence alone never proves action value.

## Random control and next gate

For each of the Top-5 rank-eligible state/path groups, the random lane chooses one feasible and nonincumbent action from the same target's four responses using a separately seeded RNG (seed 271828). The structural lane proposes a highest-scoring feasible and nonincumbent action in that same group; exact ties are sampled with independent fixed RNG seed 314159. Both lanes share the same state opportunities and would receive equal official transition budgets in Level 2. Level 1 reports the frozen pairs and action ranks; it does not run Level 2.

A known positive control that appears in Top-5 is an implementation check, not proof of unbiased discovery. The rule may not be adjusted after inspecting its rank. Independent new checkpoints are required for a general discovery claim.
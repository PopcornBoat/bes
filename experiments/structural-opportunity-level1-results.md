# Structural opportunity Level 1: Meander positive control

Protocol and implementation were committed as 59d682b before inspecting the new rollout or ranking. This is nomination only: no substituted action was evaluated, no learner was generated, and the frozen parent checkpoint was not modified.

## Inputs and audit volume

- Frozen parent SHA256: de2b3f3b09b24cd6c011afe1f8247dacfd4fc55a0381a621529a40af521a0312.
- Official Cage2-meander-100-v0, 100 seeds 11000000 + 197*i, i=0..99.
- 9,700 nonopening decisions; all 36 catalogue actions considered under the same rule.
- 197 terminal/host-observation groups, 788 state/path/action candidates, 244 eligible under the predeclared exposure and feasibility thresholds.
- The score uses only incumbent rollout observations/reward and graph/controller execution data. It is not an estimated counterfactual advantage.

## Positive-control result

User2 Restore (Semantic-36 catalogue index 17, pair (8,2)) has action rank interval 1–3 among 36. It therefore met the frozen unambiguous Top-5 criterion. Its highest-ranked group is terminal TEAM-0-33, User2 raw observation tuple [0,0,0,1], seen in 92 independent episodes and 4,344 decisions. There were 93 episodes exposing the within-terminal complementary tuple. The candidate was Controller-feasible on every group decision; direct terminal support, support reachable through that terminal's references, Top-8 presence, and actual execution were all zero in this group.

Crucially, User2 Analyse (index 13) and User2 Remove (index 24) have the exact same score and rank interval 1–3. The structure and observed reward weighted the User2 state/path highly but did not identify Restore as the uniquely valuable response. User2 Decoy (index 31) ranked 6 because it was present in the global Top-8 through an alternative route, despite lacking direct/reachable support from TEAM-0-33.

The fixed random control selected User2 Restore in the top group while the structural tie sampler selected User2 Analyse. Both were feasible and differed from the incumbent in 92 common episodes. This is a useful demonstration that Top-5 inclusion alone does not establish an advantage over matched random nomination; Level 2 is required. One of the five frozen matched lane pairs selected the same action for both lanes, so a future Level-2 protocol must specify collision handling before evaluating either lane.

## Interpretation

Level 1 reproduced the known affected host, visible state, and active terminal route without a User2-specific branch in the code. It established a candidate shortlist and the distinction between terminal support and Top-8 support. It did not show that structural information identifies the correct response, that a random lane is less efficient, or that any new action has positive official advantage. Because the positive control was known during design, this is an engineering calibration rather than an independent discovery claim.

The next experiment should freeze an equal-opportunity, equal-transition-budget Level-2 comparison before looking at any alternative-action return. It should handle tied structural actions and random collisions explicitly. A later unseen checkpoint is required to test generality.

## Artifacts

Raw and derived data are under /home/hardison/bes-artifacts/validations/meander-structural-opportunity-level1-20261029/:

- input-sha256.txt records exact inputs.
- steps.tsv contains each official nonopening decision, observation, path, support masks, Controller feasibility and reward.
- catalogue.tsv maps the 36 action indices.
- candidates.csv contains the complete ranked state/path/action table, including ineligible entries.
- action-ranking.csv contains the 36 action ranks and tie intervals.
- summary.json and lanes.json contain the positive-control check and frozen lane proposals.
- The process log is in the adjacent .log file.
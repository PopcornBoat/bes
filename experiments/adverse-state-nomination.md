# Restoring the adverse-state nomination signal

The first six-lane incubation pilot accidentally replaced, rather than
retained, the frozen Level-1 adverse-state score. That score combined
episode exposure, persistence, the observed negative-reward lift of a host
state, action support deficit and Controller feasibility. It was a
nomination heuristic, not an alternate-action advantage estimate.

On the **same** v8 rollout (`18000000 + 197i`, 100 episodes), the Level-1
action scorer still ranks User2 Restore in the tied interval 1–3 of 36.
The six-lane group scorer ranks the best User2 group seventh in its
missing-support lane, while only one group per lane is admitted. Its six
structural nominations and six same-target random controls contain no
User2 group. Replaying the newer group scorer over the earlier gen463 audit
also omits User2; thus the algorithm change, rather than the checkpoint
revision, is the main reason for the discrepancy.

The corrected protocol keeps the six newer lanes unchanged and adds the
frozen adverse-state score as a **separate seventh lane**. No other lane is
multiplied by its reward signal. Each structural nomination still receives
one same-target, exposure-matched random control. On both archived audits,
the adverse-state lane selects the User2 `0001` group. This is a host-state
nomination only; Restore must still win the four-response official screen.

The corrected Meander v8 nomination is stored in
`meander-opportunities-adverse.json` and `.sexp`. The 14-group response
manifest passed a two-seed official rollout smoke check. The revised rule
was chosen after the known positive-control discrepancy was seen; this is
an exploratory repair and cannot be presented as a blinded rediscovery of
User2 Restore. Independent checkpoints remain necessary for generality.

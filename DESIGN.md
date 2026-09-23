# Official-Guided TPG Research Design

The research question is:

> How can TPG obtain stable, local, cumulative policy improvement without gradients?

The work is deliberately split into four phases so improvements remain
attributable.

1. **Trustworthy trajectories and comparison.** Clean mixed DAgger and
   uncertainty-aware official CAGE2 challenger evaluation.
2. **Measure semantic disruption.** Observe parent/child action and ranking
   distance without changing mutation.
3. **Control semantic disruption.** Adapt mutation locality only after Phase 2
   establishes its relationship with official regression.
4. **Preserve complementary specialists.** Study grouped case-wise selection,
   lexicase, and behavioral diversity.

Phase 1 must not implement mutation-locality control, lexicase, recurrent TPG,
soft teacher distillation, or counterfactual advantage. Existing ranked
semantic imitation and mutation operators remain unchanged.

Phase 2 preserves those operators and selection rules. It adds only passive
parent/child measurement on a versioned probe archive. The measurements must
not draw from the search random state, reject a child, choose a parent, or alter
a mutation probability. Mutation-locality control remains Phase 3 work.

Phase 3 preserves Phase-1 evaluation and Phase-2 measurement. It controls the
behavioral consequence of the unchanged native mutation pipeline with bounded
resampling, while retaining an explicit non-local exploration fraction. It does
not adapt individual mutation operators and does not introduce Phase-4
population selection.

The current baseline contract is 62 policy inputs (52 raw plus 10 scan state),
a direct Semantic-36 target/response terminal genotype, stateless TPG
execution, heuristic-guided DAgger, fixed controller-owned opening, and fixed
bridge-owned Decoy ordering. The bridge owns scan and used-Decoy state.

Later phases may measure or change other mechanisms, but only on separate
branches with explicit ablations.

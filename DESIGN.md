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

The baseline contract is 62 policy inputs (52 raw plus 10 scan state), 11
semantic targets, stateless TPG execution, fixed controller-owned opening, and
fixed bridge-owned Decoy ordering. The bridge owns scan and used-Decoy state.

Later phases may measure or change other mechanisms, but only on separate
branches with explicit ablations.

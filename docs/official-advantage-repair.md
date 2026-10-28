# Official advantage directed bid repair

Date: 2026-10-27. Branch: `official-counterfactual-replay`. The parent is the frozen Meander gen-463 checkpoint recorded in [official-counterfactual-replay.md](official-counterfactual-replay.md). This is an isolated research experiment; no production search or historical best is replaced.

## Hypothesis and data split

The prior independent one-step holdout suggested that changing `(User1, Analyse)` to `(User3, Decoy)` can improve reward at eligible states. Those holdout outcomes were not used to fit this rule.

A new development block uses seeds `7000001 + 197*i` for `i=0..159`, disjoint from discovery and holdout. It replays each eligible parent episode, changes one action at step 20 or 40 when the target pair is in Top-8 and resolves to a different concrete action, then resumes the parent. It also stores every fifth parent decision as a background probe. This yields 52 eligible counterfactuals and 3,200 background samples. The one-step deltas comprise 19 greater than +0.5, 11 less than -0.5, and 22 near zero.

## What the 62 inputs can express

The 52 eligible events contain only five distinct 62-dimensional observations. Twenty-eight nonpositive events have exactly the same observation as some positive event; this includes ten of eleven negative events. Different hidden environment/controller histories or future randomness can therefore give opposite one-step outcomes at the same visible input. A stateless 62-input policy cannot make a universally correct decision for those cases.

The graph audit found that the promising observation groups follow the same route and terminal team. The terminal team already contains a `(User3, Decoy)` learner, but it ties the incumbent `(User1, Analyse)` learner at bid zero, so stable learner order keeps the incumbent as Top-1. This makes a conditional edit to the existing alternative learner's bid a narrow genotype test; no new terminal, learner, or team is needed.

## One tentative genotype edit

A two-feature categorical rule was selected from the development block: `obs[4] = 1` and `obs[43] = 0`, using zero-based observation indices. The candidate is a serialization-based deep copy of the parent. Five instructions are appended to the existing alternative learner's program: compare both features with read-only 1 and 0, multiply the Boolean results, scale by 0.001, and add the result to bid register 0. Off the gate, its original bid is unchanged. No Controller override or external action rule is added.

On the development probe, this changed Top-1 in 14/19 positive events and 5/11 negative events. It also changed 190/3,181 protected background decisions (5.97%), all toward `(User3, Decoy)`. This collateral is too large to regard the probe alone as evidence of a safe repair. The sum of selected positive one-step deltas (+41.5) is a diagnostic quantity, not an expected closed-loop policy return.

## Fresh official comparison

Evaluation seeds: `8000001 + 197*i`, `i=0..99`. Parent and child each run a complete official `Cage2-meander-100-v0` episode, sequentially reset to the same seed. Initial simulator-state digest and policy observation must match for every pair. The two policies can consume RNG differently after their first action divergence, so paired deltas compare full trajectories from the same initial condition, not identical later random events.

The parent mean was -22.658 (SD 4.692), and the child mean was -22.559 (SD 4.748). The paired child-minus-parent delta was +0.099 (SD 4.086, SE 0.409), with 44 wins, 40 losses and 16 ties. The approximate 95% interval is [-0.70, +0.90]. Eleven seeds lost more than 5 reward and eleven gained more than 5; observed extremes were -13.1 and +10.0. This is no reliable closed-loop improvement. The candidate is not promoted and the parent checkpoint remains untouched.

The first concrete-action divergence occurred in 88/100 paired episodes, at mean step 11.8. The development intervention was measured only at step 20 or 40, so this rule fires much earlier on most trajectories. Identical visible observations at beneficial and harmful events, together with these early triggers, explain why the one-step advantage does not transfer to a reliable policy gain. This does not show that every bid repair fails; it rejects this specific two-feature gate.

Raw evaluation: `/home/hardison/bes-artifacts/validations/official-counterfactual-20261027/repair-evaluation.sexp`.

## Reproduction

```bash
cd /home/hardison/bes-artifacts/worktrees/official-counterfactual-replay
bash scripts/run-official-development PARENT_CHECKPOINT development.sexp
bash scripts/analyze-official-development development.sexp development-analysis.sexp
bash scripts/audit-official-repair-graph development-analysis.sexp PARENT_CHECKPOINT graph-audit.sexp
bash scripts/build-official-repair development.sexp development-analysis.sexp PARENT_CHECKPOINT repair-candidate.lisp repair-probe.sexp
bash scripts/evaluate-official-repair PARENT_CHECKPOINT repair-candidate.lisp repair-evaluation.sexp
```

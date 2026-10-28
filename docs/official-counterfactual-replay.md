# Official counterfactual replay audit

Date: 2026-10-27. Experimental branch: `official-counterfactual-replay`, based on `9ad6015`. Production search and protected checkpoints were not modified.

## Question

Can official CAGE2 reward reveal a repeatable beneficial one-step policy deviation before we modify a TPG genotype? This experiment uses no teacher labels or teacher policy queries. It does not train or promote a policy.

Frozen Meander policy: `/home/hardison/bes-artifacts/validations/meander-bid-guidance-gen463-20261026/checkpoints/bid-guidance-gen463.lisp`, SHA-256 `de2b3f3b09b24cd6c011afe1f8247dacfd4fc55a0381a621529a40af521a0312`. Environment: `Cage2-meander-100-v0`, 62-input stateless Semantic-36, fixed opening, fixed Meander Controller option order. Checkpoint instruction and read-only-register profiles are restored from its metadata.

## Replay fidelity

CybORG `set_seed` calls Python's global `random.seed`. Its simulation `save/restore` methods are stubs, so this implementation replays the same seed and concrete-action prefix sequentially. Never interleave two environments in one Python process while using the global RNG.

The bridge-only audit ran 100-step identical semantic-action tapes for B-line and Meander at seeds 153, 42 and 2026. It repeated each tape in the same environment instance and a new instance. All six cases matched exactly on every observation, reward, resolved concrete action, Python RNG state, bridge scan/decoy state, and a pickle digest of `SimulationController.state`. This covers the tested tapes, not every possible action or software version. The entire `EnvironmentController` cannot be pickled because it contains a `mappingproxy`.

The TPG audit additionally ran the frozen checkpoint twice for each of five discovery seeds. All 100 steps matched on policy observation, incumbent pair/ranking, concrete action, reward, next observation, Lisp Controller state, and a digest comprising simulator state, Python RNG, and bridge state. Every counterfactual branch checked this same digest and the concrete-action/reward/observation/Controller prefix before intervention. No mismatch occurred. The digest does not prove equality of every unpicklable agent/controller field, so the result is strong practical replay evidence rather than a formal complete-state snapshot.

## Discovery

Seeds: 153, 42, 2026, 314159, 271828. At steps 5, 20, 40, 60 and 80, take the first two executable Top-8 alternatives that resolve to different concrete actions. Change only that step, then resume the frozen incumbent. The 25 decision points yielded 50 branches: 8 positive, 10 negative, 32 effectively zero; overall mean delta was about +0.002. Total official cost was 6,000 transitions, including exact baseline reruns. The selected discovery group was incumbent `(7,0)` to alternative `(9,3)`: User1 Analyse to User3 Decoy. It occurred three times, with deltas 0, +5, and +4.9. Selection used only this discovery block.

## Independent confirmation

The hypothesis was frozen before running holdout: test `(7,0) -> (9,3)` at step 20 or 40, only when the alternative appears in the incumbent Top-8 ranking and resolves to a different legal concrete action. For each episode, test the first qualifying event. Holdout seeds were `6000001 + 197*i`, `i=0..119`; none are discovery seeds.

Of 120 holdout episodes, 48 had an eligible event. Their one-step paired deltas were 16 positive, 7 negative and 25 zero. Mean delta was +0.896, sample SD 2.954 and SE 0.426. The normal-approximation 95% interval is roughly [+0.06, +1.73]. This borderline interval depends on the observed gain magnitudes; the 16 wins versus 7 losses among nonzero cases provide weaker sign-only evidence. Largest observed loss was -7.1 and largest gain +10.7. The 27 step-20 events averaged +1.48; the 21 step-40 events averaged +0.14. Official cost: 16,800 transitions (120 baselines and 48 branches).

These are conditional effects among qualifying events. The branching seed is shared only up to the intervention; after divergent actions, RNG consumption and later events need not remain aligned. The confirmation block is independent of discovery, but it does not estimate the return of a deployable policy rule. The nominal interval is narrow above zero; do not treat it as a robust global gain or ignore the observed losses.

## Decision

A reproducible, teacher-free local official-reward signal exists for this frozen Meander checkpoint under the stated state-group definition. This justifies a **small, isolated advantage-directed symbolic repair experiment** next. A candidate TPG change must express the beneficial deviation on 62-input observations while preserving behavior at protected states, especially late states. The observed phase difference cannot simply be put into the TPG as a step-index feature under the current 62-input contract. Its genotype must then pass direct-parent paired evaluation and the unchanged fresh-seed promotion/tail protocol. No genotype repair was implemented here.

The result does not justify a broad forced Decoy rule, a teacher-based override, or memetic bid fitting. If a localized repair cannot reproduce this group without collateral changes, that is evidence about genotype expressibility/routing, not a failure of the one-step reward measurement.

## Reproduction

```bash
cd /home/hardison/bes-artifacts/worktrees/official-counterfactual-replay
/home/hardison/venv-base/cage2_bridge/.venv/bin/python scripts/replay_fidelity.py
bash scripts/run-official-counterfactual /home/hardison/bes-artifacts/validations/meander-bid-guidance-gen463-20261026/checkpoints/bid-guidance-gen463.lisp /home/hardison/bes-artifacts/validations/official-counterfactual-20261027/pilot.sexp
bash scripts/run-official-counterfactual-holdout /home/hardison/bes-artifacts/validations/meander-bid-guidance-gen463-20261026/checkpoints/bid-guidance-gen463.lisp /home/hardison/bes-artifacts/validations/official-counterfactual-20261027/holdout.sexp
```

Raw results and logs: `/home/hardison/bes-artifacts/validations/official-counterfactual-20261027/`. The holdout seeds have now been inspected and must never be reused as final promotion evidence.

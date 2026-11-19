# Fixed-graph terminal policy-gradient feasibility study

## Scope

Branch live/torch-terminal-policy-gradient.
Frozen B-line mother SHA256:
cda3f1d75bdec6a6622974af492d4396753f427619d41afcd93d3509a9e12994.

This is a teacher-free online actor update using PyTorch autograd. It is not the
previous Gaussian ES estimator reimplemented with tensors. Official return
provides training evidence; no PPO/heuristic labels or donors are used.

The first study trains only 2008 existing numeric parameters in 263 pure
atomic terminal teams. Upstream team-reference bidding/routing parameters,
graph structure, instructions, terminals, EQ categorical constants, ROR,
62-input interface, fixed opening and native Controller remain frozen.
This prevents deep stochastic graph routing from being conflated with terminal
numeric learning in the initial feasibility experiment.

The preceding numeric ES trial mainly identified less destructive directions;
its only fresh-100 candidate lost 1.236 reward. Four probe seeds could dominate
that parameter-space estimate. This study tests a different credit mechanism:
actual per-decision likelihood gradients, with a value baseline, rather than
whole-vector return differences. It does not assume this mechanism succeeds.

## Native-compatible actor

Export the entire fixed graph with raw instructions, canonical team slots,
atomic action payloads and the exact ROR bank. Existing eligible numeric
coordinates use the same IDs and parameter units as the numeric-search branch.
Only coordinates in pure atomic terminal teams are nn.Parameter entries.

A fast functional scalar interpreter computes rollout bids. An independent
PyTorch functional register interpreter recomputes those same bids for training.
Both implement native instruction clipping, protected division and categorical
EQ semantics. No Tensor graph is retained through the simulator.

At each visited eligible pure terminal team:
- p_i = (1-epsilon)*softmax(bid_i / temperature) + epsilon/n.
- Temperature 0.25, epsilon 0.01.
- Sample one first-ranked learner. The remaining learners retain their native
  stable descending bid order.
- Reuse the sampled order if the same team is encountered again in that query.

All mixed/reference teams keep their deterministic native ordering.
The normal hierarchical DFS emits up to eight distinct Semantic-36 candidates.
The existing Lisp Controller alone resolves that complete ranking, including
Restore Top-1 restriction, Decoy availability and global scheduling.

Training records the latent selected-learner probability. It does not pretend
the Controller-delivered concrete action has that same probability. Joint
log-probability sums all sampled team choices used to construct the ranking,
once per cached team. This permits policy-gradient credit through the unchanged
deterministic Controller, with possible nuisance variance from equivalent
rankings.

When sampling is disabled, the original stable hard ranking is used.

## Update and training-only value baseline

The objective is undiscounted official 100-step episode return.
After each episode compute actual return-to-go. A separate 62->64->1 Tanh
value network predicts a baseline from the same policy-accessible inputs.
It is used only during training and is never exported with the TPG.

Warm up this critic on 16 hard-mother episodes. This is self-experience return
regression, not action imitation or teacher mixing.

For each update:
1. Collect eight genuine on-policy stochastic episodes with unchanged weights.
2. Compute advantage = return-to-go - the previously fitted value prediction.
3. Normalize advantages across the batch.
4. Recompute differentiable bid programs and selected-learner log probabilities.
   Assert recomputed old likelihoods match rollout likelihoods within 1e-8.
5. One Adam step on -advantage*joint_log_prob - 0.001*entropy.
6. Clip actor gradient norm to 1; constrain normalized coordinate changes to
   +/-0.5. Existing units are max(0.05,min(5,0.1*abs(initial_constant))).
7. Estimate sampled likelihood KL. If above 0.02 or invalid, restore actor and
   Adam state and halve its learning rate.
8. Fit the value baseline on the completed batch after the actor update.

Actor learning rate starts at 0.02. Critic learning rate is 0.001.
This is Monte Carlo REINFORCE with a learned baseline and a step guard;
it is not a claim to implement PPO or TD actor-critic.
EQ and hard upstream branches are not made globally differentiable.
CPU float64 is used for semantic fidelity and small-batch execution.

## Matched controls and evaluation

Two independent roots: 202611190801 and 202611190802.
Each has:
- learn: actual parameter updates.
- frozen: the same stochastic ranking mechanism with numeric weights frozen.

Modes share episode seeds and private per-episode sampling RNG seeds. Sampling
does not consume the environment's global random/NumPy RNG. Same seeds couple
initial conditions; post-divergence randomness need not remain eventwise paired.
The frozen control isolates learning from changes due to stochastic execution.

Each trial runs 32 updates of eight 100-step training episodes.
Every four updates, each learning trial exports its numbers to a standalone
Lisp checkpoint and evaluates it with original deterministic Lisp hard bidding
on 12 new paired episodes. These checks do not steer ongoing actor updates.
Torch is not used to choose actions in those native evaluations.

After training:
- Verify exported native rankings against the corresponding trained Torch
  model on all observed check contexts, with zero new environment interactions.
- Select the best monitored snapshot and retain the final snapshot.
- Compare up to two distinct snapshots with the mother on 100 fresh paired
  episodes per root.
- Never replace protected historical best or deploy automatically.

Stochastic training return is not the deployment score. Hard export and fresh
paired confirmation determine whether an improvement exists. These are pilot
confirmations, not replacement for the established full validation.

The training scope and exploration mechanism differ from the preceding ES
experiment. This is not a perfectly scope-matched ES-vs-policy-gradient study.

## Budget

Four trials have 108,800 warmup/training transitions.
Two learning trials have at most 38,400 paired hard-check transitions.
Final confirmations have at most 60,000 transitions.
Nominal full-study upper bound: 207,200 official transitions.

Completed engineering smoke consumed 1800 additional transitions, including
200 independent hard-reference steps. Bid/gradient/ranking parity tests and
archived rollout replay used zero additional official interactions.

Every worker owns its own environment, Controller, Python bridge, Torch model,
optimizer and private sampling RNG. Four independent processes run concurrently.
A partial failed trial is preserved; it is not automatically rerun and charged
silently. Resume of an interrupted rollout is not implemented.
.pt files retain numeric actor state, critic, both optimizer states and updates.

## Verification completed before launch

- 314,368 native/Torch/fast-interpreter bid comparisons: maximum error 0.
- 66 complete native Top-8 rankings: identical.
- Seven real parameter finite differences: maximum error 5.52e-9.
- Protected zero-division forward/backward: finite, zero gradients on masked branch.
- 200 native hard official transitions: identical observations, actions and rewards.
- Five focused unit tests: probability bookkeeping, shared-team caching,
  nonterminal parameter freezing, score-function direction and hard semantics.
- Two smoke actor updates: nonzero gradients, accepted steps, valid native export.
- Trained smoke checkpoint: 31 native/Torch hard ranking contexts agree.
- Frozen smoke: zero numeric updates and exact first-batch stochastic trajectories
  matching the learner before its first update.
- Recorded rollout update replay: old/new log-probability accounting verified
  without any new official interaction.

## Monitoring

Runtime:
/home/hardison/bes-artifacts/runtime/torch-terminal-policy-gradient-20261119

    cd /home/hardison/bes-artifacts/runtime/torch-terminal-policy-gradient-20261119
    tail -F monitor.log

monitor.log reports updates, episodes, last-eight stochastic mean, KL, changed
parameter counts, hard-check count and completion per trial. It ends with ALL_DONE.

Detailed learning logs:

    tail -F full/root-202611190801/learn/trainer/worker.log \
            full/root-202611190802/learn/trainer/worker.log

The final DONE file in each trial means native confirmation has also completed.
TORCH_TRAINING_DONE by itself precedes final confirmation.

Artifacts per trial:
- manifest.json and requests.sexp: frozen protocol and all seeds.
- torch-trajectories.jsonl: complete 62D inputs, sampling choices/probabilities,
  ranked proposals, native executed actions, reward, per-host loss and return-to-go.
- episodes.jsonl and updates.jsonl.
- snapshot-*/candidate.lisp and patch.sexp.pt.
- hard-checks.json, export-parity.json and confirmation/.
- results.json and DONE.

No Red sessions or other privileged hidden state enter policy inputs or loss.
Per-host reward breakdown is logged for retrospective attribution only.


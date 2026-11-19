# Fixed-graph numeric policy tuning

## Question

Treat a frozen TPG as a fixed computational graph and flatten its existing
learnable numbers into a parameter vector. Can numeric perturbations improve
official closed-loop reward, and can return differences provide a useful
black-box search direction?

This experiment does not convert TPG execution into a linear network. Graph
routing, EQ, clipping and argmax remain. Its primary purpose is to test the
directional value of numeric-only search while eliminating structural mutation.

## Frozen architecture and coordinates

Branch: live/numeric-policy-tuning.

Mother: B-line auto-f3ad4823d3, SHA256
cda3f1d75bdec6a6622974af492d4396753f427619d41afcd93d3509a9e12994.
It is the protected starting policy of the preceding continuous-search study,
not the unconfirmed latest numerical-score winner.

Frozen architecture: 1519 teams, 9824 learners, maximum graph depth 128.
Preserve all edges, terminals, programs, opcodes, destination registers, source
kinds, observation/register indices, instruction counts, 62 inputs and Controller.
No instruction, learner, gate, route or specialist is inserted.

There are 22,254 existing literal constant operands:
- 2247 constant-bid weights, eligible.
- 13,120 effective arithmetic constants, eligible.
- 2009 EQ categorical constants, frozen.
- 2631 ineffective instruction constants, frozen.
- 2247 redundant ADD-zero operands of direct constant bidders, frozen.

Thus the full numeric vector has 15,367 eligible coordinates.
General computed bids do not have a standalone mutable bid field: changing an
existing arithmetic constant changes their output. Programs with no eligible
constant have no adjustable parameter in this first study. ROR values stay fixed.
No affine bid adapter or additional instruction is introduced.

parameters.tsv maps each scalar to canonical team, learner, instruction and
operand. All candidates are serialized standalone native TPG checkpoints.
The writer checks a canonical immutable-structure fingerprint and verifies
every changed coordinate and every unchanged numeric field after roundtrip.

## Two matched scopes

- all: perturb all 15,367 eligible coordinates.
- active: perturb every eligible coordinate belonging to teams actually visited
  during the frozen mother's 16 fresh 100-step episodes. Include losing learners
  in visited teams; no host, action, learner or known successful patch is chosen
  manually.

The two scopes share the mother, stage seeds and Gaussian perturbations on
common coordinates. Their discovery data are training material, not holdout.
Unvisited teams can become relevant after decisions change; the active mask is
a bounded local approximation, not a claim those coordinates never matter.

## Random search and direction estimation

Parameter units are fixed from the mother:
s_j = max(0.05, min(5, 0.1*abs(theta_j))).

Use normalized coordinates x, theta = theta0 + s*x. For each of 16 independent
Gaussian vectors u and each sigma in {0.05,0.5}, evaluate x = +/- sigma*u.
All 64 offspring share four discovery evaluation seeds and frozen continuation.

Estimate:
g_hat = (1/(2*m*sigma)) * sum_i ((J_plus_i - J_minus_i) * u_i).

This is an antithetic Gaussian ES estimate of a smoothed, seed-averaged objective.
It is not backpropagation through official CAGE2 and not an exact derivative of
the deterministic argmax policy. Small perturbations may return zero throughout
a plateau. Sixteen directions in a high-dimensional space provide a noisy,
low-rank directional estimate. No accuracy claim is made.

For each sigma, independently evaluate on 40 fresh shared episodes:
1. Best random perturbation from the probe batch.
2. One step in the estimated direction.
3. An equal-magnitude opposite step.
4. An independent random step with exactly matched normalized norm.

The direction step has normalized RMS sigma. If the estimate is exactly zero,
no fictitious gradient step is generated; retain the random baseline only.
Report paired gradient-versus-opposite and gradient-versus-random differences,
not just their separate differences from the mother.

At most two positive-mean, noncatastrophic candidates receive a further 100 fresh
paired episodes. This is exploratory confirmation, not formal deployment or
historical promotion. No full-validation improvement is assumed.

## Budget and isolation

Per scope maximum:
- Discovery/identity: 2 policies * 16 episodes * 100 = 3200.
- Probe: (64 candidates + baseline) * 4 * 100 = 26,000.
- Validation: (8 candidates + baseline) * 40 * 100 = 36,000.
- Confirmation: (2 candidates + baseline) * 100 * 100 = 30,000.
- Total 95,200 official transitions; enforced cap 96,000.

Two scopes together have nominal maximum 190,400 transitions and enforced caps
summing to 192,000. Flat directions or no positive validation reduce usage.
Engineering smokes are recorded separately.

Each scope uses up to three independent SBCL/Python/environment workers.
The original mother's bytes, checkpoint metadata contract and deployment remain
protected. All stage seed blocks are disjoint and exclude recorded older seeds.
The two studies intentionally share each stage's seed block for comparison.

## Checks

- Five focused math tests include a known quadratic gradient, flat objective,
  matched-length random control, coordinate mapping and double precision.
- Exact empty-patch serialization reproduces the mother's full observations,
  Top-8, concrete actions and rewards episode-by-episode.
- Every native candidate enforces immutable architecture and frozen fields.
- Static graph validation verifies acyclicity and legal maximum traversal depth.
- The copied diagnostic path helper's off-by-one was corrected: 128 legal
  nodes now log successfully; 129 fails as in native traversal. Policy traversal,
  its limit and checkpoint execution semantics were not changed.
- A completed all-coordinate smoke exercised a nonzero estimate, forward,
  opposite and matched-random evaluations. This was an engineering check, not
  evidence that numerical guidance improves reward.

## Run and monitor

    python3 -u scripts/numeric_policy_tuning.py --scope all \
      --output /home/hardison/bes-artifacts/runtime/numeric-policy-tuning-20261119/all

    python3 -u scripts/numeric_policy_tuning.py --scope active \
      --output /home/hardison/bes-artifacts/runtime/numeric-policy-tuning-20261119/active

Launchers redirect each stdout to that scope's progress.log.

    cd /home/hardison/bes-artifacts/runtime/numeric-policy-tuning-20261119
    tail -F all/progress.log active/progress.log

Each scope writes:
- inventory/parameters.tsv, structure.sexp and topology.tsv.
- coordinates.json, original parameter values and units.
- probe-build/models/proposals.json and each native numerical variant.
- gradients.json with coordinate estimates and plus/minus return responses.
- direction-check.json with fresh paired controls.
- results.json and budget.json.
- Complete paired official trajectories in each stage's worker directories.
- DONE when finished.

The source checkpoint is never overwritten, no teacher is queried, and no
positive discovery sample is treated as formal improvement.


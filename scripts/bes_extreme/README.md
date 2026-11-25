# BES extreme-optimize

Use `extreme-optimize` to improve a frozen BES bundle against a designated official seed root, normally 153. This is a bounded late-stage search over the existing Controller and TPG policies. The input bundle contains the opponent router, the B-line graph, the Meander graph, the Controller's Decoy schedule, and the pinned evaluation sources. Sleep uses the Controller's existing benign action.

The optimizer shares its graph primitives with [route compilation](../tpg_compilation/README.md).

## Search and selection

1. Score the input bundle on all nine official cells (B-line, Meander and Sleep at 30, 50 and 100 steps). Each cell uses the official continuous-reset sequence from the specified root. Candidate comparisons reuse the same roots and episode counts.
2. Search single-host Decoy order permutations in round-robin host order. For each eligible host the Controller tries the exact same Decoy options in a different sequence. The Top-8 ordering of Decoy hosts, fixed opening and availability rules continue to govern execution.
3. Combine the highest-scoring improving single-host orders across pairs of hosts. Test each combined schedule in the full closed loop. Supply enough single-host budget to evaluate all permutations when reproducing the original schedule search.
4. Optionally trace the current leader. An observable context is eligible when exchanging Top-1 and Top-2 on the complete eight-action ranking would change the concrete action under the native Controller. Repeated exposure to observed loss raises the context's priority for testing. The optimizer compiles each edit into ordinary TPG learners using the existing 62 inputs. The compiled candidate must match the intended ranking and reproduce the incumbent ranking on the 62 one-coordinate near misses checked at compile time. It skips graphs for which it cannot establish the required fallback reachability and depth. The exported policy executes the compiled graph through the Controller.
5. Use official closed-loop score to select the leader. Repeat until a round produces no improvement or reaches the round limit. Compare the final leader with the original bundle on the configured holdout roots. The default requires the mean holdout total to at least match the original and the count of 100-step episodes below −100 to stay at or below the original for each root and opponent. The run records 100-step CVaR₁₀ separately. A failed holdout retains the original in `best-policy/`.

Each graph nomination is a hypothesis about an opportunity. Observed loss is a priority signal. Closed-loop evaluation captures the downstream consequences of applying the edit repeatedly. Exact observation predicates can specialize to root 153. The aggregate holdout check allows variation by root, and a small or repeatedly consulted holdout provides limited evidence of generalization. The exported bundle contains the three graphs and Controller configuration. The search leaves training and historical-best files untouched.

## Run it

Run from a BES checkout on Linux or WSL. Use Python 3.11+, SBCL, the ASDF dependencies for the frozen BES code, and the pinned official CybORG installation. Set `BES_PYTHON_VENV` if the bridge virtual environment is outside `$HOME/venv-base/cage2_bridge/.venv`. Set `BES_ASDF_DEPENDENCIES` to a Quicklisp dependency tree if SBCL cannot find dependencies in the default Quicklisp locations.

The bundle format follows the archived pure-graph result. It uses `policy.json`, `inputs/`, `support/` and `code/`. The manifest identifies the three graph files and their SHA-256 digests, the schedule, the Controller hash, and the official evaluator. The ranked-host protocol and fixed opening `[51, 116, 55]` are required. The mode checks the installed CybORG version and official evaluator hash. Every run fingerprints its installed simulator sources and pinned BES sources for reproducible resumes.

```bash
bundle=/tmp/bes-root153
scripts/bes-search materialize root153 "$bundle"
run="$HOME/bes-artifacts/runtime/extreme-optimize-153"

scripts/bes-search extreme-optimize \
  --bundle "$bundle" --output "$run" --plan-only

scripts/bes-search extreme-optimize \
  --bundle "$bundle" --output "$run" \
  --root 153 --holdout 42,290150561 --episodes 1000 \
  --rounds 1 --single-budget 24 --joint-budget 8 --graph-budget 2 \
  --workers 2 --max-transitions 21600000
```

One full bundle evaluation costs 540,000 transitions (9,000 episodes). The example bounds the run at 40 evaluations, including the input score, the traced evaluation and four holdout evaluations. It can finish earlier if fewer candidates qualify. Use `--graph-budget 0` for schedule-only search, `--hosts Enterprise0,Defender` to restrict the schedule search, or `--evaluate-only` to score a bundle as-is. Official workers run in independent processes. The driver can resume with the same settings and verifies completed results before reusing them. Run `scripts/bes-search extreme-optimize --help` for the full interface.

Results are under the supplied output directory.

| Path | Contents |
| --- | --- |
| `manifest.json` | Frozen inputs, seed roots, budgets and source fingerprints |
| `rounds.json` | Candidate changes, official totals, evidence paths and round leaders |
| `jobs/*/worker.log` | Worker progress |
| `jobs/*/evaluation/` | Per-step concrete actions and rewards, per-episode returns and official score decomposition |
| `graphs/` | Compiled graph candidates, compiler logs and verification records |
| `result.json` | Fixed-root winner, holdout comparison and selected export |
| `source-policy/`, `best-policy/` | Original and selected bundle copies |

The run's `best-policy/` can be supplied to `--bundle` for a new run. Use a separate output directory for independent validation. For a quick regression test, run `python3 -B tests/test_extreme_optimize.py` from the repository root.

## Measured results behind the mode

In the archived root-153 experiment, the pure-graph baseline scored **−57.2553**. Searching one host at a time found Enterprise0 order `[6, 7, 2, 0]` at **−56.7823**. The best joint configuration used Enterprise0 `[6, 2, 0, 7]` and Defender `[7, 2, 0, 6]`. It reached **−56.6674**, a gain of 0.5879 over baseline and 0.1149 over the best single-host result. These were full 30/50/100 official evaluations. See the [experiment log](../../EXPERIMENTS.md).

The archived Meander Restore edit also reached −56.6674 on root 153 and improved the tail on some other roots. The six-root mean gain was only +0.0191. That edit motivates testing graph changes in the closed loop. The automatic Top-1/Top-2 generator in this mode has been exercised in a small official smoke run, including holdout rejection. Its effectiveness at full scale remains to be measured.

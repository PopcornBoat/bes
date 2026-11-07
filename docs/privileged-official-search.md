# Fixed-seed privileged official search

Branch `online-privileged-search` starts from `online-official-specialists`.

The search reads simulator internals for training diagnostics while executing
ordinary 62-input, stateless Semantic-36 TPG policies. Internal observations
include real sessions and privileges, Blue suspected PIDs, host reward
components, executed Red/Blue actions and Red progress where available.

## Algorithm

1. Freeze the input checkpoint and configuration with SHA-256 hashes.
2. Run its full episode on each discovery seed, record all 62 policy inputs,
   ranked actions, active team paths, Controller states and privileged snapshots.
3. Replay without the observer and require identical observations, actions,
   rewards and simulator digests. Before every action intervention, verify the
   complete original prefix including privileged snapshots.
4. At each selected step, enumerate all 36 semantic alternatives. Skip proposals
   that Controller cannot resolve or that execute the incumbent concrete action.
   Execute one substitute action, then let the frozen TPG finish the episode.
5. Rank completed interventions by full remaining-return difference. This is a
   same-prefix intervention measurement under a frozen continuation policy.
6. For the highest positive opportunities, enumerate one- and two-feature
   equality predicates across all 62 current inputs. Try a narrow single gate
   and two narrow double gates, bid margins 250/1000, and insertion at the root
   or active terminal team. These are serialized learner additions to independent
   graph copies. Preserve the existing Decoy scheduler and opening.
7. Evaluate each active genotype over complete discovery episodes. Reload its
   saved checkpoint and require exactly reproduced returns. Keep the highest
   full-policy mean only when it improves on the parent.
8. Repeat from that candidate, up to the round budget. A round with no improvement
   ends the run. Its best path is written to `search-summary.sexp`.

Gate selection uses current observations and their baseline activation counts.
Internal state is recorded to explain reward effects. It never enters runtime
predicates. Seed and step select experimental intervention points only. Learned
genotypes contain ordinary TPG programs and terminals, so they run through the
existing validation and deployment interfaces.

## Run and monitor

From WSL:

```bash
cd /home/hardison/bes
scripts/run-brute-official-search /home/hardison/bes-artifacts/runtime/brute-meander-153 \
  --red meander --seeds 153 --rounds 1
```

The default source is frozen Meander v9. For B-line, `--red b_line` selects
frozen v14. To select another source, pass `--checkpoint PATH`.

The default intervention set is steps 3..99 and all 36 actions, with at most
3500 executable trials per round. Budget-limited enumeration follows seed,
step, then action order. Multi-seed runs should raise the branch budget to cover
all seeds. Default synthesis evaluates at most 24 variants from up to four
positive opportunities. Variant generation follows opportunity rank, gate,
insertion and margin order. Increase `--max-candidates` for broader synthesis.
Up to three greedy rounds are allowed by default.

Run inside tmux and redirect output to a log. Monitor with `tail -f LOG`.
Interrupt safely with Ctrl-C or stop the tmux process. Repeat exactly the same
command to resume completed trial/candidate results. An exclusive directory lock
prevents concurrent writers. Different settings or source hashes require a new
output directory. Per-trial and summary files are atomically published.
`completed-rollouts.sexp` counts completed official episodes and transitions.
An episode interrupted before completion may have consumed additional transitions.

## Outputs

- `manifest.json` and `source.lisp` preserve the original experiment inputs.
- `round-N/baseline-SEED.sexp` contains the full original trace.
- `round-N/trial-SEED-STEP-ACTION.sexp` records the intervention, bid competition,
  private pre/post state and exact return difference.
- `round-N/positive-*.sexp` retains complete positive intervention trajectories.
- `round-N/interventions.tsv` and `report.md` provide a readable opportunity ranking.
- `round-N/candidate-*.lisp` are standalone TPG genotypes. Candidate result files
  record gate definitions, full discovery returns and baseline behavior changes.
- `search-summary.sexp` identifies the final discovery best and its evidence level.

## Interpretation

The search is bounded and covers a specific family of edits. Exhausting its
budget can yield no improvement. A positive single-action intervention may turn
into a harmful repeated gate, so complete candidate episodes decide acceptance.
Narrow gates can still trigger at the wrong times under observation aliasing.

Fixed discovery seeds make debugging and repeated comparison practical.
Selection on those same seeds creates overfitting risk. The outputs are
discovery candidates and are saved separately from production historical best.
Use fresh seeds and the existing official full-validation/promotion protocol
before importing a result into the maintained online training line.

The initial engineering smoke uses the previously studied Meander v8,
seed 153 and User1/User2 Restore. It checks replay, observer isolation,
interventions, standalone serialization and rejection of harmful candidates.
That control is separate from new opportunity discovery on v9 or B-line v14.

# Continuous official-return search

This is a persistent teacher-free online incubation engine. A single command
automatically repeats experience collection, nomination, genotype generation,
paired closed-loop evaluation, bounded lineage retention and fresh validation.
No host, desired action, known catastrophe or episode index is prescribed.

The existing 160-root main.lisp evolutionary loop and grouped selection are
unchanged. This entry point owns a separate bounded candidate population and
serialized neutral lineages. Its incumbent is local to its run directory. It
does not write existing historical-best files or automatically replace deployed
experts. Deployment of a newly promoted policy is a separate explicit operation.
The former active-specialist subprocess still exists in the legacy entry point;
invoking that old training command does not run this new search.

## Frozen deployed expert pair

The deployment validation entry point is scripts/validate_expert_dispatch.py.
The once-per-episode recognizer follows the existing fixed three-action opening,
selects B-line / Meander / Sleep at j=3, then retains that selection. Controller
state is preserved across handoff.

- B-line auto-f3ad4823d3, SHA256 cda3f1d75bdec6a6622974af492d4396753f427619d41afcd93d3509a9e12994.
- Meander e2-analyse, SHA256 3b9c6a4f11ffdbc28551c3eb65201a333b4ce8c8f2b8ad225659c6ee22459010.
- Recognizer SHA256 8864b37e6b3a80536cf2246df508182a3adc849e16cfb37e2e143bd3da87c834.

These experimental experts have prior separate full validations. The smoke check
verifies all three opponents and horizons, and compares every routed concrete
action with direct expert execution for B-line and Meander. This does not imply
a new statistically confirmed combined performance gain.

## Autonomous cycle

1. Collect 24 fresh incumbent 100-step episodes.
2. Enumerate all Semantic-36 alternatives in target-symmetric observable groups.
   Check actual current Controller resolution and record displaced actions.
3. Independently nominate rare, persistent-state, repeated-choice and random
   opportunities. Normal 0000 states remain eligible. These are nomination
   signals, not estimates of causal action value.
4. Generate up to 16 proposals. Half the allocation targets conditional action
   delivery; the rest uses existing native field-local instruction, atomic
   terminal and team/graph mutation. No donor or teacher is loaded.
5. Use the same generator for all specialist lanes. Predicates initially match
   observed current 62D inputs; they become normal TPG programs with EQ/MUL.
   Previously retained neutral parents may receive another directed change.
6. Validate serialization; probe real Controller-delivered actions; filter
   duplicate and inactive candidates. A bounded observed probe cannot certify
   global equivalence or guarantee behavioral safety.
7. Shared-seed 12-episode screening, fresh 40-episode racing, fresh 100-episode
   confirmation. Early screens only eliminate clear adverse evidence. Confirm
   up to four lane-balanced candidates rather than select only one noisy maximum.
8. At most one positive-mean confirmed candidate per cycle receives a fresh
   full 1000 episodes for each of 30/50/100 steps. A positive 100-episode mean
   merely allocates validation budget; it is not promotion evidence.
9. Promotion retains the existing >1-SE mean comparison criterion. Require
   non-adverse horizon checks, no observed new < -100 episodes, and CVaR10
   degradation no worse than 0.25. Zero observed disasters is not proof of no risk.
   The normal-approximation statistics can be fragile for rare events.
10. Keep at most four behaviorally distinct exploration lineages. Officially
    uncertain candidates may reproduce without replacing the incumbent.
11. Advance automatically with new experience and seeds. Do not retest an
    identical incumbent/opportunity pair repeatedly. Native mutations continue
    to provide unguided exploration.

The native Semantic-36, 62 inputs, stateless execution, fixed opening, fixed
Cardiff global schedules and existing Decoy/Restore Controller contract remain
unchanged. History and host loss are training diagnostics only. No privileged
Red state is recorded or used.

## Run and monitor

Use WSL Python and the existing CAGE2 venv-backed SBCL bridge.

    python3 scripts/continuous_official_search.py \
      --opponent b_line --checkpoint /absolute/frozen-checkpoint.lisp \
      --output /absolute/run/b_line --workers 3 --cycles 24 \
      --transitions 2000000

Run Meander separately with --opponent meander and a separate output directory.
Each has three independent SBCL/Python worker processes, bounded queues and its
own environments. No new batch is submitted before the previous stage finishes.

    tail -F /absolute/run/b_line/progress.log /absolute/run/meander/progress.log

The launcher redirects each command to its progress.log. events.jsonl is the
append-only event log; state.json stores incumbent, serialized lineage paths and
hashes, independent seed cursors, completed jobs, opportunity history and budget.
Each cycle stores the full catalogue, generation plan, candidate provenance,
probe behavior and paired 62D/action/reward/per-host-loss/path/bid trajectories.
results.json records concrete-action activation, first divergence, displaced
actions, restore cost, host reward, means/SE, tails and new catastrophes.

To stop after the current cycle, create OUTPUT/STOP. Remove it to resume. Reuse
the same command and output path. Source and protocol hashes are checked.
Completed jobs are reused; interrupted attempts are archived and budgeted
conservatively before retry. Saving serialized parents and reconstructing
working graphs is intentional; whole-population memory snapshots are not used.

The default bound is 24 cycles or 2 million reserved official transitions per
opponent, whichever comes first. Successful completed transitions and all
reserved interaction costs are separate. A full finalist costs 360,000 steps
including its matched incumbent. A default cycle without full validation costs
at most 92,800 steps: 2,400 discovery + 20,400 screening + 20,000 racing +
50,000 confirmation.
Budget reservations may stop a run before all 24 cycles. Actual active candidate
counts can be much smaller after read-only filtering.

## Verification and interpretation

    python3 -m unittest discover -s tests -p test_continuous_official_search.py -v

Seven focused tests cover independent/restorable seeds, exact Controller rules,
normal-state eligibility, episode independence, permissive negative filtering,
final safety gates and atomic persistence.

The 2026-11-18 engineering runs established:
- Recognizer dispatch and direct experts agreed action-by-action across all
  tested B-line/Meander horizons; Sleep returned zero.
- Six archived episodes, including each expert's worst archived 100-step case,
  were exactly reproduced by the new official evaluator.
- A two-cycle Meander smoke resumed at cycle 1 and preserved the incumbent;
  second-cycle native offspring inherited retained parents and activated.
- Episode sums equal recorded returns and the per-host/Restore decomposition.

These checks establish executable automation, not improved learning efficiency.
Use confirmed positive offspring and validated promotions per official
transition to assess whether this search works. All-zero progress, repeated
inactive mutations, adverse candidates or absent fresh gains remain legitimate
negative research results. No performance improvement is guaranteed.


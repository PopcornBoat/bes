# Phase 5C: Rare-failure diagnosis

Phase 5C-1 diagnoses the low-frequency catastrophic returns observed in the
Phase-5B version-17 incumbent. It does not change training or promotion.

The runner reconstructs the episode seeds from the saved ordered validation
result, replays both the protected Phase-4a policy and version 17, and records
the heuristic ranking, both policy rankings, controller resolution, concrete
action, reward, and controller state at every step. Proposal queries are pure;
the controller is updated only from the action executed in the environment.

Run it with:

```bash
./scripts/phase5c-trace \
  FULL_VALIDATION_RESULT \
  PHASE4A_CHECKPOINT \
  VERSION17_CHECKPOINT \
  OUTPUT_DIRECTORY
```

The launcher uses a 4 GiB SBCL dynamic space. It writes `seed-audit.sexp`,
`trajectories.sexp`, `summary.sexp`, and `input-sha256.txt`. All candidate
returns must reproduce the saved validation result before the traces are used
for causal diagnosis.

Known failure seeds become development evidence after inspection. They must
not be reused as untouched confirmation evidence for a later promotion.

## Phase 5C-2: causal correction replay

After Phase 5C-1 identifies a repeated first-disagreement mechanism, run:

```bash
./scripts/phase5c-causal \
  FULL_VALIDATION_RESULT \
  VERSION17_CHECKPOINT \
  OUTPUT_DIRECTORY
```

The 4 GiB runner replays each audited failure normally, with exactly the first
teacher disagreement corrected, and with every teacher disagreement corrected.
Only the executed decision updates controller state. A one-shot rescue is
evidence for a local causal repair; persistent correction is an upper bound,
not a deployable policy and not promotion evidence.

## Phase 5C-3: targeted proposals under official return credit

The audited version-17 failures share a systematic Case-B first disagreement:
the teacher's `(Enterprise0, DECOY)` is absent from Top-8 in eight of nine
episodes. Correcting only the first disagreement rescues five of nine episodes;
correcting every disagreement rescues all nine. The treatment therefore does
not hard-code one action or train on those nine seeds.

Phase 5C-3 warm-starts from protected version 17 and combines one existing
ten-percent Case-A/B proposal quota with the Phase-5B paired child/direct-parent
official-return gate. Targeted children retain the existing group-improvement,
collateral-damage, and behavioral-locality gates. They receive bounded lineage
protection only after fresh paired official evidence, while the global incumbent
still requires the unchanged fresh 12/40/100 promotion protocol.

Run with `experiments/phase5c-targeted-return-credit.sexp`. Checkpoints use the
isolated `official-guided-targeted-return-credit` filename and directory. The
nine diagnostic seeds are development evidence only and cannot serve as fresh
promotion or final confirmation seeds.

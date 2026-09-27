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

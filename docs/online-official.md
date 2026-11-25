# Teacher-free official online evolution

Use this branch for official-return search and bounded specialist discovery. Candidates share a training seed in each generation. Confirmed specialists can enter reproduction. Staged fresh-seed official promotion decides updates to the historical best.

To continue from a validated checkpoint, start either launcher with its own fresh run directory.

~~~bash
scripts/run-bline-official-online /path/to/new-bline-run
scripts/run-meander-official-online /path/to/new-meander-run
~~~

The launchers name their frozen inputs and verify their SHA-256. They select the historical Decoy profile used by those checkpoints. The Meander launcher continues from v9. The historical v8 to v9 experiment started from [v8](../validated-checkpoints/meander-v8/README.md), generated a User2 Restore specialist automatically, and produced the [v9 validation](../validated-checkpoints/meander-v9/README.md). Its baseline and final totals were -39.3888 and -32.3672.

See [active specialist search](../experiments/teacher-free-online-specialists.md) for the worker, seed roles and official promotion rules.

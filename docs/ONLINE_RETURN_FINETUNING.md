# Teacher-free official-return fine-tuning

This opt-in online experiment warm-starts a protected 62-input, flat-36,
stateless checkpoint. The fixed opening and fixed decoy-order controller remain
part of the policy. No teacher trajectory, label, ranking, or imitation fitness
is generated or used.

Each generation evaluates every root on the same five fresh CAGE2 episode
seeds. Mean official return ranks the population; 15% of survivor places are
reserved for distinct per-seed specialists. Candidate inspection rotates three
aggregate nominations, one per-seed specialist, and one random nomination.
The random lane is for inspection only, not automatic survival.

A candidate is frozen alongside the incumbent and compared in a separate
process. A five-seed shared-seed racing screen and cumulative fresh promotion
blocks of 30, 50, and 100 episodes can only reject. The final 1,000-seed
stage alone can replace the incumbent, and requires paired multi-horizon
improvement plus the existing tail-safety audit. Training, racing, promotion,
and fixed-root monitoring seeds are disjoint streams. Fixed-root scores never
decide promotion. The run-local checkpoint is saved immediately after a
successful final promotion using the existing deep serialization copy.

Seed-stream cursors and submission count are journaled in
`online-return-state.lisp`; checkpoints also contain their stream snapshot and
promotion evidence. Warm-start deliberately rebuilds the population, but a
same-run resume requires a matching journal to avoid silent seed reuse.

Fresh import request: `experiments/online-return-finetuning.sexp`; same-run
warm-start request: `experiments/online-return-resume.sexp`. The source v14
checkpoint is read-only; the run writes only to its own checkpoint directory.
The worker result files contain full paired evidence, while
`online-return-history.lisp` contains compact stage summaries.

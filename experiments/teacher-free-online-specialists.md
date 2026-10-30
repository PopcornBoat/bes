# Teacher-free online specialist search

This experiment warm-starts from the frozen Meander v8 graph. It does not
pre-import a repaired graph. The previous one-shot opportunity pipeline is a
diagnostic baseline and is not the training mode used here.

Run `scripts/run-meander-official-online RUN_DIRECTORY` in a tmux session.
The launcher uses port 8082, starts an independent Emacs monitor, and sends a
`:resume-search` request with mode `:official-online`, 62 inputs, Semantic-36,
one official episode per candidate per generation, and a stateless fixed-order
controller. The `:teacher-backend :heuristic` request field selects the
existing Meander Decoy order profile; no teacher is queried.

Every population member is scored by official episode return on the same
generation seed. Training seeds change each generation and use a persisted
stream separate from admission, racing, promotion, and specialist discovery.
The historical incumbent remains a serialized deep copy and can change only
after the existing staged official promotion protocol.

At generation 1 and then at least 100 generations after each launch, the
search freezes the current incumbent and asynchronously runs:

1. Official trajectory and TPG structure audit.
2. Multi-signal opportunity nomination and official action screening.
3. Conditional specialist synthesis, behavioral probe, official admission,
   and independent confirmation.
4. Import of a confirmed graph as a bounded population evidence anchor,
   followed by the normal fresh-seed promotion protocol.

An opportunity worker writes only under its own cycle directory. A completed
worker is discarded if the incumbent version changed. Discovery and screening
never directly replace the historical best. `cycle-complete` is written only
after the whole worker succeeds; incomplete cycles cannot be imported.

Monitor the Emacs window on port 8082 or attach to the tmux session. The
worker log is under `checkpoints/.active-specialist/cycle-*/worker.log`.
The soft Meander diagnostic is whether the search independently nominates,
admits, and eventually executes User2 Restore. It is not hardcoded into the
search or its acceptance threshold.

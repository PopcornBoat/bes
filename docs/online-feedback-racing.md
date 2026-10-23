# Paired online feedback racing

This experiment warm-starts the protected 62-input, semantic-36, stateless
Meander policy and trains against official CAGE2. The original checkpoint is
read-only; results go to a separate directory.

Each generation evaluates the population and incumbent on one shared training
seed. Training return nominates candidates; it never replaces the incumbent.
Two ordinary offspring slots probe `+0.1` and `-0.1` changes to one effective
bid-program constant in the same parent. Their paired return differences are
provisional direction feedback, not a gradient and not promotion evidence.
Ordinary TPG program, learner, action, and graph mutation remains active.

At most five candidates are retained per evaluation batch: four by paired
training delta and one reservoir-sampled random control. An independent worker
races them against the frozen incumbent on the same fresh episode seeds at
3, 10, and 30 episodes. Early stages may reject clear regressions but cannot
promote. The best survivor is tested on 100 new paired promotion seeds; only
a positive one-standard-error margin may replace the incumbent. The fixed
seed-153 reference is monitoring only. Racing and promotion seed cursors are
persisted in the checkpoint and a sidecar so rejected batches do not reuse
their seeds after restart. The winning graph is still deep-copied by
serialization before saving.

Run the smoke checks:

```sh
bash /home/hardison/bes-artifacts/worktrees/online-feedback-racing/scripts/smoke-online-feedback
```

Start the full run (requires port 8080 to be free):

```sh
bash /home/hardison/bes-artifacts/worktrees/online-feedback-racing/scripts/launch-online-feedback train
```

Monitor the running WSL Emacs dashboard, or read its recent messages with
`bash /home/hardison/bes-artifacts/worktrees/online-feedback-racing/scripts/online-feedback-status`.
The server log is
`/home/hardison/checkpoints/semantic36/meander-online-feedback-train-v2/server.log`.
Use `scripts/stop-online-feedback` to request a clean search stop.

The small constant probes may be behaviorally neutral even when the bid value
changes; their nonzero rate should be measured before claiming that signed
feedback improves search.

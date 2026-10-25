# Paired online feedback racing

This experiment warm-starts the protected 62-input, semantic-36, stateless
Meander policy and trains against official CAGE2. The original checkpoint is
read-only; results go to a separate directory.

Each generation evaluates the population and incumbent on one shared training
seed. Training return nominates candidates; it never replaces the incumbent.
A separate, fixed 72-state probe archive samples early and late official
trajectory steps. Each entry preserves the policy observation and a pre-action
copy of the external Controller state. It identifies effective bid constants
close to a winning boundary along paths the policy actually visits.
Two offspring slots try opposite changes to one such constant. Only variants
with bounded Top-1/Top-8 ranking changes and a nonzero, bounded change in the
Controller-resolved concrete action are kept. The Controller is queried purely
on its frozen snapshot; the variant does not update its state. A path copy
isolates internal-team changes from the parent. One-seed return differences are
provisional direction feedback, not a gradient or promotion evidence. Ordinary
TPG program, learner, action, and graph mutation remains active.

At most five candidates are retained per evaluation batch: priority candidates
by paired training delta, one reserved directional candidate, and one
reservoir-sampled random control. An independent worker
races them against the frozen incumbent on the same fresh episode seeds at
3, 10, and 30 episodes. Early stages may reject clear regressions but cannot
promote. The best survivor is tested on 100 new paired promotion seeds; only
a positive one-standard-error margin may replace the incumbent. The fixed
seed-153 reference is monitoring only. Racing and promotion seed cursors are
persisted in the checkpoint and a sidecar so rejected batches do not reuse
their seeds after restart. The winning graph is still deep-copied by
serialization before saving. Worker results record each candidate's lane,
paired delta, standard error, and survival at every stage; the winner's
promotion returns are also retained.

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

The path-local probes can still fail to improve official return. Compare the
directional lane with the ordinary and random lanes before claiming that
signed feedback improves search.

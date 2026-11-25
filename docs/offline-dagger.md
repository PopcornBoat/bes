# Offline and DAgger training

Use this branch to reproduce ranked Semantic-36 imitation, grouped epsilon-lexicase and official-guided DAgger. Replay contains states visited by the learner and ranked labels from the Lisp heuristic. Official staged promotion makes the historical-best decision.

Start the BES runtime with scripts/bes-runtime start. Copy the relevant request to a working directory, set its output directory, and submit it with scripts/bes-search submit REQUEST.sexp.

| Opponent | Request | Starting point | Independently validated endpoint |
| --- | --- | --- | --- |
| B-line | [evolved candidate admission](../experiments/evolved-candidate-official-admission.sexp) | Frozen v13 | [v14](../validated-checkpoints/bline-v14/README.md), -28.4841 |
| Meander | [Meander heuristic request](../experiments/meander-heuristic-official-guided.sexp) | Fresh population | [v8](../validated-checkpoints/meander-v8/README.md), -39.3888 |

The historical requests specify the Decoy profile used in those experiments. Reproduction requires the correct seed roots and a separate run directory. The B-line starting checkpoint and its matching journal are frozen at the archive/bline-v13-training-start tag. Extract the tag into a new directory, verify SHA256SUMS and update best-team-path in your request to the extracted checkpoint. The maintained common code and the official release on main use the same checkpoint format.

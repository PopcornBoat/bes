# BES checkpoint and activation audit

The tools consume trusted BES checkpoints and archived traces. They do not
create or step a CybORG environment. The frozen Controller and graph-loading
code used in the original release remain separate from this analysis.

## Reproduce a checkpoint figure

Use WSL with SBCL, the local Quicklisp dependency trees and Graphviz. Use the
pinned BES source tree that matches the checkpoint evaluation. A custom
Common Lisp dependency tree can be named by BES_ASDF_DEPENDENCIES.

    python scripts/tpg_research/visualize_tpg.py \
      --checkpoint /path/to/checkpoint.lisp \
      --traces /path/to/checkpoint-traces.json \
      --code /path/to/pinned-cl-tpg \
      --output /path/to/new-directory --mode activation

The output has an exact backup and a separate `*-pruned.lisp`. The trace
manifest records the checkpoint SHA-256, trace format, path and task. When an
optional source SHA-256 is present, the CLI verifies it. Omit --traces for
Full Graph export. Use --reuse-audit against an existing verified output to
recompute counts and figures without changing checkpoints or context files.

Stored Team IDs come from serialized definitions. Learner identity combines
its owning Team with its serialized slot. The original serialized Learner
ID is preserved in the table. References resolve to the existing Team ID.
The audit compares actual original and pruned Lisp program bids and candidate
rankings for every unique recorded input, alongside an independently traced
deterministic traversal. Rank attribution uses the first path that emitted a
semantic action. An observed source lacking the fields required for
Controller attribution contributes only its supported measurements.

Structural liveness is the backward dependency slice of the bid for these
stateless Semantic-36 policies. The pruning pass also preserves potentially
trapping operations and their dependencies. It preserves all Learners, Teams,
and reference edges. For unsupported observation or state contracts the
Lisp entry point rejects the input.

## Optional future recording

`runtime_trace.ActivationTrace` opens an optional native JSONL or JSONL.gz
trace. Omit its filename to disable recording. A pure graph driver calls
`record` after each successful environment step, keeping the decision's
pre-step 62D input, Decoy mask, native ranking, and actual execution.
Supply the Controller's delivered rank and semantic pair when available.
Use a trace manifest entry with `format: native`, `path`,
`task`, `checkpoint_sha256`, `profile` and `resolution`. The pair is
written as the canonical `host:response` string. Evaluation and training
remain independent of the trace file.

A minimal future verification is two episodes per cell for the original and
pruned Controller bundles under an agreed root. Check exact agreement in
concrete actions, reward, opening and routing, repeat with recording enabled,
and compare the trace's rank with the concrete action identity. Enable larger
official evaluations only when explicitly wanted. The current report required
zero new environment transitions.

## Expert paper graphs, radar and observation indexing

To reproduce the compact expert panels, first export OBS operands for each
immutable backup using SBCL with the same source registry as the graph audit.

    sbcl --script scripts/tpg_research/checkpoint-audit.lisp observation-sources \
      /path/to/original-backup.lisp /path/to/audit/program-observation-sources.tsv

Then run `expert_figures.py --report <report-directory>` in the analysis
virtual environment and regenerate the landing page with `figures.py`.

Each expert panel starts at its serialized Root Team. It shows the most
frequent verified delivered candidate path for each response family in that
expert's own archive. The intersection panel counts only Teams on those
displayed paths and names the response families explicitly. Use the
activation-only and Full Graph exports for complete graph evidence.

Index-frequency bars count actual operand reads during archived bids.
Action associations and feature pairs use the static bid-live index set
along the verified delivered path. Read counts may exceed one per query if
the same observation is accessed multiple times. The output CSVs preserve
the indices and the exact concrete host-response grouping.

On the host radar, 1 is zero observed mean host loss. The 0.5 mark
corresponds to the larger observed mean loss of the two arms on that axis
(except for the small minimum plotting scale). The Decoy radar uses
deployments per episode divided by the axis cap published in its CSV.

## Semantic-36 checkpoint radars

Run semantic_radars.py --report <report-directory>, then figures.py to
regenerate the index. Response-mix radars compare all four responses.
Host-targeting radars show the nine allowed targets within each response.
The companion heatmap gives changes for the complete 36-cell vocabulary.
Rates use all 100-step post-opening decisions as the denominator. Top-1
and final Controller delivery are separate, and any actions outside the
catalogue are recorded separately in the CSV and provenance summary.

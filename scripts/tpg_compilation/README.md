# Compile a route catalogue into a native TPG

A catalogue is trusted Lisp data of the form (("observation" ((target response) ...)) ...). Each observation has 52 binary values and 10 scan-state values in 0, 1 or 2. Each ranking has eight distinct Semantic-36 pairs. The optional legacy input has nine Decoy counts between the observation and ranking. Rows sharing an observation must agree on all eight ranks.

The compiler builds a balanced EQ routing tree using ordinary TPG reference learners. Every leaf checks all 62 values before returning its ordered terminal learners. Other observations follow the original graph. Ranked terminal leaves with identical outputs are shared. The converter requires a stateless Semantic-36 fallback with adequate reachable action support and no cycles or excessive depth.

The exported checkpoint is independently reloaded and compared against every catalogue key. Archived contexts supplied with --contexts also verify the full Top-8, Controller resolution and availability state. The output path is reserved only after the checks pass. The output graph executes through the native Controller and graph traversal.

## Reproduce the Meander v15 conversion

~~~bash
scripts/bes-search materialize root153 /tmp/bes-root153
scripts/bes-search materialize meander-v15-reference /tmp/bes-v15-reference
scripts/bes-search compile-routes \
  --bundle /tmp/bes-root153 \
  --checkpoint /tmp/bes-v15-reference/fallback.lisp \
  --catalogue /tmp/bes-v15-reference/catalogue.sexp \
  --contexts /tmp/bes-v15-reference/archived-contexts.sexp \
  --legacy-counts --meander-v15 --opponent meander \
  --output /tmp/bes-meander-v15-recompiled.lisp
~~~

The explicit --meander-v15 switch preserves the two archived Restore-priority exceptions. The original full A/B validation compared the external table with native v15 at root 153 with the pre-extreme Decoy schedule. Both arms scored -57.2553, with matching concrete trajectories and returns for 9,000 episodes. Recompilation can change checkpoint bytes while preserving rankings and delivered behavior.

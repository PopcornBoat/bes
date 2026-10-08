# Current Research Status

Updated: 2026-10-07

## Canonical state

- Repository: `/home/hardison/bes`
- Branch: `incumbent-anchored-conservative-repair`
- Bridge: `/home/hardison/venv-base`
- Policy: 62 inputs, direct Semantic-36 terminals, stateless execution
- Controller: global heuristic Decoy schedule, protocol v2
- Teacher: deterministic Lisp B-line heuristic

## Established result

The fixed global Decoy schedule changed the unchanged evolved checkpoint from
`-41.8542` to `-33.2618` in official full validation. The compiled heuristic
TPG scored `-28.9498`. The remaining gap is `4.3120`.

The active configuration retains the mechanisms with positive or necessary
evidence: clean DAgger, behavioral-locality measurement, bounded semantic
locality, grouped epsilon-lexicase, official paired comparison, tail-aware
promotion, immediate independent best saving, and Controller v2.

Targeted routing/composition, teacher-directed correction, return-credit
lineages, and near-miss lineages are disabled by default. Their implementation
is retained only for historical reproduction and ablation work.

## Next research question

The compiled heuristic proves that the current TPG representation can express
the desired policy. The next work should compare the evolved checkpoint and
compiled heuristic at disagreement states under the same controller, then use
that evidence to improve evolutionary routing without changing the policy
contract or controller semantics.

The random atomic-predicate treatment stopped cleanly at generation 680. It
created more than four thousand complete categorical predicates with mean
Top-1 disruption near five percent and retained high population diversity, but
none of those lineages reached official evaluation. Teacher Top-8 coverage
improved while Top-1/response agreement did not. The frozen baseline is:

```text
/home/hardison/checkpoints/semantic36/frozen/random-categorical-predicate-gen680-20261007/
```

The population-parent single-predicate treatment was stopped at generation 565.
It admitted 745 of 4,510 local repairs and sent 55 challengers to official
evaluation, but none promoted. Only 27 challengers improved their direct parent,
and higher local separation/coverage was negatively correlated with official
return. Its frozen evidence is stored at:

```text
/home/hardison/checkpoints/semantic36/frozen/teacher-guided-predicate-gen565-20261007/
```

The active treatment addresses that failure without changing official
promotion. Every targeted child is cloned from the frozen incumbent, restricted
to repeated early or step-10--29 Top-8 omissions, and receives only one new
direct specialist. Its gate is the conjunction of two exact categorical
predicates, its winning bid is calibrated from incumbent root bids, and it must
cause zero Top-1 changes over a broad current on-policy background before it can
enter selection. The normal paired racing protocol therefore compares the
repair to the same incumbent that generated it.

## Recovery archive

The complete pre-cleanup Git refs and working tree are stored outside the
repository at:

```text
/home/hardison/bes-artifacts/repository-archive/2026-10-01-before-mainline-cleanup/
```

The Git bundle was verified before branch and file cleanup.

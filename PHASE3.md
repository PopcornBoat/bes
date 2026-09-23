# Phase 3: semantic-locality control

Phase 3 changes only offspring generation. It retains the frozen Phase-1
official-guided DAgger/evaluation protocol and all native TPG mutation
operators, and it retains Phase-2 measurement. It does not add lexicase,
recurrent registers, a new fitness objective, or operator-specific adaptation.

## Mechanism

Each offspring slot chooses one of three tiers:

| Control age | Local | Bounded | Explore |
|---:|---:|---:|---:|
| 0-249 | 60% | 25% | 15% |
| 250-999 | 75% | 20% | 5% |
| 1000+ | 85% | 12% | 3% |

- `local` requires a non-neutral change with both Top-1 Hamming and ranking
  distance at most `0.05`.
- `bounded` requires a non-neutral change with both distances at most `0.20`.
- `explore` accepts the first native mutation with no locality restriction.

Local and bounded slots make at most eight independent attempts. Every attempt
runs the existing `mutate-team` pipeline unchanged. If no attempt meets the
tier, the least-disruptive attempted child is retained. A probe-neutral child
is therefore available as a safe fallback but is not treated as a useful local
change. The bounded retry prevents stalls and the explore tier prevents a hard
locality cap from trapping the search permanently.

Rejected temporary children are fully removed with `delete-team`, including
team-reference accounting, and are removed from the signature cache. Only the
accepted child is eligible for selection, lineage tracking, and passive
official sampling.

## State and audit data

The Phase-3 age is part of behavioral-locality checkpoint state. Restoring a
Phase-3 checkpoint continues the same schedule. A Phase-2 checkpoint starts
Phase 3 at control age zero.

Each accepted record stores:

- schedule stage and control age;
- requested tier;
- number of attempts and whether fallback was used;
- all attempted distance strata;
- the existing instruction/learner/terminal/edge mutation events;
- the accepted child's full Phase-2 behavior metrics.

Generation summaries are appended to `behavioral-locality-records.lisp` as
`:locality-control-generation` forms. The dashboard log reports attempts,
retries, fallbacks, tier counts, and accepted-stratum counts.

## Experimental boundary

This branch (`semantic-locality-control`) is the Phase-3 treatment. The pushed
`semantic-locality-analysis` branch remains the unchanged Phase-2 control.
Phase-3 official-guided checkpoints use `official-guided-locality-control` in
their filename and therefore cannot overwrite the Phase-1/2 incumbent.

A useful run should show all of the following before judging return:

1. `explore` remains non-zero over sufficiently many generations;
2. accepted large-Top-1 mutations fall sharply relative to Phase 2;
3. retry/fallback rates remain finite rather than saturating every child;
4. generation-best and official challengers continue to appear;
5. fresh-seed staged promotion, not imitation fitness, remains the only way to
   replace the protected historical incumbent.

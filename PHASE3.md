# Phase 3: semantic-locality control

## V2 adaptive continuation

The first v1 run stopped at generation 596.  It reduced accepted large Top-1
changes, but its latest 100 generations reached an 83.8% retry-fallback rate
and 87.9% probe-neutral accepted behavior.  No official challenger was
promoted.  V2 therefore keeps the same native mutations, schedule, thresholds,
official comparison protocol, and explicit explore quota, but changes retry
exhaustion for a requested `local` slot:

```text
accepted local mutation
  or
least-disruptive bounded non-neutral attempt
  or
probe-neutral fallback
  or, only if neither exists, least-disruptive exploratory attempt
```

This avoids preferring a no-op merely because its numerical distance is zero,
without converting every saturated local slot into an unbounded mutation.
V1 control state is accepted on resume and retains its control age.

V2 also journals post-selection population behavior and detailed DAgger
disagreement diagnostics.  These measurements do not change mutation,
selection, fitness, or random-state consumption.

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
- requested and effective tier, plus whether fallback escalated;
- number of attempts and whether fallback was used;
- all attempted distance strata;
- the existing instruction/learner/terminal/edge mutation events;
- the accepted child's full Phase-2 behavior metrics.

Generation summaries are appended to `behavioral-locality-records.lisp` as
`:locality-control-generation` forms. The dashboard log reports attempts,
retries, fallbacks, tier counts, and accepted-stratum counts.

The same journal also receives:

- `:population-diversity-generation`, containing unique Top-1/ranking
  fingerprints, mean pairwise Top-1 Hamming, normalized action entropy,
  teacher Top-8 mean/union coverage, expressed pair count, and the dominant
  Top-1 pair/rate;
- `:dagger-disagreement-generation`, containing target/response agreement,
  phase-specific disagreement, the teacher-to-TPG confusion table, and the
  TPG prediction distribution.

## Experimental boundary

This branch (`semantic-locality-control-v2`) is the adaptive Phase-3 treatment.
The pushed `semantic-locality-control` branch preserves the v1 treatment, and the
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

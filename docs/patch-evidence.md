# BES patch evidence ledger

This ledger separates measured policy improvement from engineering correctness,
diagnostic value, and changes that have not demonstrated an official-return
benefit. A run improving after a patch is not attributed to that patch unless
the new mechanism was exercised and the available evidence supports the link.

## Demonstrated policy or execution improvements

| Change | Evidence | Conclusion |
| --- | --- | --- |
| Controller v2 fixed decoy scheduling | The same evolved checkpoint improved from full-validation total `-41.8542` to `-33.2618` | Strong direct improvement; retained globally |
| Grouped epsilon-lexicase | Full validation improved from `-55.0362` under scalar selection to `-46.2352`; unique Top-1 behavior rose from about 2 to about 34 | Strong evolutionary improvement and diversity preservation; retained |
| Semantic-36 target/response terminals with external fixed decoys | The compiled heuristic fits in one team with 29 learners/197 instructions and validates at `-28.9498` | Representation is sufficient and substantially easier to reason about than register-decoded options |
| Field-local mutation plus reduced arithmetic profile | Fresh reduced search reached `-34.0480` and ran faster; the compiled heuristic needs only the reduced arithmetic core | Useful search-cost reduction, but not independently superior in reward to every full-operator run |
| Incumbent-conservative run | Independent full validation moved from evolved v12 `-33.4040` to v13 `-32.9590` | Small real run-level gain; neither promotion was directly produced by the repair injector, so attribute the gain to the treatment run/warm restart rather than the injector |

## Necessary correctness and selection infrastructure

| Change | What it established |
| --- | --- |
| Immediate serialize/deserialize historical-best copy | Removed shared-reference checkpoint corruption and keeps saved best independent |
| Clean teacher query and canonical controller state | Prevents unexecuted teacher/student proposals from mutating scan/decoy state |
| Training/racing/promotion/reference seed streams | Makes candidate comparisons reproducible and prevents seed reuse across decision roles |
| Paired official racing and frozen staged promotion | Rejects lucky short evaluations; only the final fresh-seed stage may replace historical best |
| Multi-horizon/tail-aware promotion | Prevents a short-horizon or rare catastrophic-tail regression from being hidden by one scalar mean |
| Protected warm-start checkpoint semantics | Population reconstruction cannot overwrite the source best without final official promotion |
| Controller/protocol/checkpoint provenance | Prevents comparing scores produced by incompatible action/controller contracts |

These changes improve trustworthiness rather than directly promising a better
policy. They remain part of the maintained baseline.

## Mechanically useful or diagnostic, without a demonstrated direct reward gain

| Change | Result |
| --- | --- |
| Behavioral-locality archive and mutation telemetry | Showed catastrophic regression probability rises sharply with behavioral radius; valuable diagnosis |
| Bounded locality control | Confirmed large mutations are risky, but strict gates caused retry exhaustion and many neutral children |
| Effective-code analysis and intron pruning | Reduced one checkpoint from 100,462 to 13,089 instructions with exact probe-ranking preservation; clear size/speed value, no isolated reward gain |
| Periodic compression/reseed | Safely injects compact variants, but observed improvements have not been causally tied to the event |
| Disagreement, rare-failure, and counterfactual diagnostics | Located systematic failure groups and action/return mismatches; diagnostic only |
| Compiled heuristic checkpoint | Proves capacity and supplies an oracle/reference; it is not evidence that evolution can discover the same graph |

## No demonstrated benefit in the tested form

| Change | Evidence |
| --- | --- |
| Pure offline behavioral cloning | Good row-level scores did not prevent closed-loop trajectory drift |
| Hamming projection | Sometimes improved an offline checkpoint, but exact-hit coverage remained low and it did not solve the main online problem |
| 142-input availability vector | No convincing gain over the maintained 62-input controller contract |
| Recurrent registers | Prototype did not establish an official benefit and complicated reset/checkpoint semantics |
| mini/DT environments | Fast, but transfer bias and seed sensitivity made them unsuitable as the main selection environment |
| ROR constant bank alone | No official promotion by about generation 949 |
| EQ/categorical equality alone | No meaningful promotion by about generation 976 |
| Random complete categorical predicates | Created thousands of predicates and increased behavioral support, but no official challenger reached promotion |
| Teacher-guided predicates | 745 of 4,510 local repairs passed local gates; none of 55 official challengers promoted, and local separation was negatively associated with official return |
| Targeted routing repair | Modest Top-k support changes; no official promotion before stop around generation 508 |
| Specialist composition | 210 of 5,022 proposals accepted; 62 official challengers, zero promotions |
| Combined targeted repair | 115 of 4,654 proposals accepted; 57 official challengers, zero promotions |
| Paired local credit | 29 comparisons, 3 local approvals, no global promotion |
| Bounded near-miss lineages | One global promotion occurred, but the winner was not an active lineage and failed direct-parent credit; no causal evidence for the lineage mechanism |
| PPO teacher fresh control | Best observed full result about `-49.3564`; no improvement over the heuristic-guided mainline |
| Coordinated repair bundles | 896 attempts produced zero accepted bundles and all fell back with `NO-SAFE-COORDINATED-CHILD` |

## Current hypothesis and next treatment

Across many treatments, a warm-start reconstruction or new patch often finds
one or two early improvements and then plateaus. At the same time, targeted
operators frequently fail to produce a usable child even when the population
still has moderate behavioral diversity. This supports testing search coverage
directly, without weakening official promotion.

`population-diversity-partial-restart-v2` therefore replaces a configurable
fraction of the population after 400 generations without official promotion.
At population 160, the default 50% treatment retains 80 roots and rebuilds 80
slots from one independent incumbent copy plus 79 fresh random roots. The root
population remains exactly 160. Pulses have a 400-generation cooldown and an
independent RNG stream.

This is intentionally different from permanently doubling population size:
the treatment isolates periodic diversity renewal, bounds sustained compute and
memory, preserves half the evolved population, and never relaxes official promotion.
Its benefit is not yet established; it requires an official-guided run and
independent full validation.

The live treatment uses profile `LIVE-DIVERSITY-V2`: expensive behavioral-
locality sampling/control and all unsuccessful repair injectors are dormant.
This removes the observed per-generation locality-worker cost while retaining
grouped selection, clean ranked DAgger, official comparison, and promotion.

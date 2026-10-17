# Validated CAGE2 policy-learning route

This page records the established BES route and its frozen results, not a
catalogue of experimental treatments. B-line and Meander use separate
heuristic teachers and controller Decoy schedules, but the same TPG policy
contract and evaluation principles.

## Why this route was developed

The route was built in response to observed failure modes, not by assuming
that each added mechanism improves reward on its own:

| Observed problem and consequence | Why we tested the maintained response | What the evidence establishes |
| --- | --- | --- |
| Complete-action or target-plus-register outputs made the intended host/response decision hard to inspect and repair. A large concrete action space also made the policy search less focused. | Use direct Semantic-36 `(target, response)` terminals, leaving concrete Decoy choice to the controller. | A compiled heuristic fits in one TPG team and scored `-28.9498` under the current controller. This establishes representational sufficiency, **not** that evolution will automatically discover it. |
| Decoy availability is controller state. Feeding an extra 80 availability inputs or using recurrent registers did not establish a transfer benefit; the earlier per-target Decoy schedule also disagreed with the heuristic's actual global order. | Keep the policy at 52 raw + 10 scan inputs, and give the controller the global fixed Decoy schedule and actual-action state updates. | Fixing the schedule alone changed the **same** evolved checkpoint from `-41.8542` to `-33.2618` in official full validation. This is direct evidence for the controller correction; it does not isolate a reward effect for 62 versus 142 inputs. |
| High offline row-level imitation did not prevent the learner from visiting different states and losing return over a full episode. Unexecuted teacher proposals could also corrupt stateful labels. | Label learner-visited trajectories with clean DAgger: query the deterministic Lisp heuristic without side effects, then update controller state only from the action actually executed. Keep ranked imitation so a useful teacher action below Top-1 still provides signal. | This makes the training labels correspond to the learner's real trajectory. It is a training/correctness rationale, not an isolated claim that DAgger or ranking caused a particular checkpoint score. |
| Fast mini/digital-twin environments did not reproduce official validation reliably; using only those returns to choose a best policy risked optimizing a surrogate-specific trajectory. | Use the Lisp heuristic to make guided trace generation practical, but keep candidate admission, racing, promotion, and final validation on official CAGE2. | This addresses simulator-transfer bias by measuring the outcome that will actually be deployed. It is a validity choice, not a claim that official evaluation is computationally cheap. |
| Scalar imitation selection collapsed the population toward a few similar winners, discarding complementary target/response specialists. | Test grouped epsilon-lexicase while retaining the ordinary TPG bidding and graph evolution. | In the controlled comparison, unique Top-1 fingerprints rose from roughly 2 to 34 and full validation improved from `-55.0362` to `-46.2352`. This is direct evidence for specialist preservation and a run-level reward gain. |
| Small genotype edits sometimes caused large policy changes and catastrophic official regressions; imprecise instruction edits also spent search effort outside the effective bid-producing code. | Measure parent/child behavior, favor bounded and field-local/effective-code edits, retain an explicit unrestricted exploration fraction, and test a smaller arithmetic instruction profile. | Behavioral-radius measurements explain the risk; a reduced-profile fresh run reached `-34.0480` faster. The categorical constant bank and exact-predicate operators are available, but their individual reward contributions have **not** been established. Locality control is not a guarantee of improvement. |
| Short stochastic episodes and imitation scores could make a candidate look better while its closed-loop return or 100-step tail was worse. A saved best also once risked sharing mutable graph references. | Compare policies on paired official seeds, use disjoint fresh-seed staged promotion and long-horizon/tail checks, and save accepted bests immediately as independent serialized graph copies. | These are correctness and selection safeguards: they make promotions more trustworthy and checkpoints stable, rather than directly increasing policy capability. Shared seeds align initial RNG state, not every later event after actions diverge. |
| The aggregate imitation champion was not necessarily the best official-return candidate; a narrow nomination gateway could miss unusual but useful descendants. | Add specialist, behavioral-diversity, critical-error, and random-control nomination lanes. Use cheap evaluation only to reject clear failures; send survivors through paired batch comparison and fresh confirmation. | The evolved B-line v14 and Meander v8 checkpoints below are outcomes of this maintained route. The random lane also measures whether the more directed nomination lanes beat an unbiased control. Those outcomes do not prove that every lane independently helped. |
| Even a favorable long-horizon mean can be dominated by a few rare trajectories and can reverse across fresh seed roots. | Freeze important checkpoints, validate all three horizons independently, then compare them on disjoint fresh roots with paired returns and lower-tail metrics before declaring a robust improvement. | A Meander v8-versus-online-challenger audit found that three of 800 paired 100-step episodes drove nearly all of the apparent mean difference. The audit stopped us from treating that small, seed-sensitive difference as robust evidence of improvement. |

The causal distinction matters: Controller v2 and grouped epsilon-lexicase have
direct controlled evidence above; the compiled heuristic establishes capacity;
the remaining retained components either keep the experiment valid or form the
working search route. Failed or inconclusive treatments are kept out of this
success-only page and evaluated separately in
[the patch-evidence ledger](../docs/patch-evidence.md).

## Policy contract

- The deployed policy is a standalone, stateless TPG with 62 inputs: 52 raw
  CAGE2 observations followed by 10 scan-state values. The controller owns
  Decoy availability; the policy does not consume the extra 80 bridge values.
- A terminal represents one of 36 `(target, response)` pairs. TPG bidding and
  graph traversal produce a ranked semantic proposal list. The controller
  selects an executable proposal, follows the opponent-specific fixed global
  Decoy order, and converts it to a concrete CAGE2 action.
- The first three actions are fixed controller probes. Controller state is
  updated only from the observation, concrete action, and transition that
  actually occurred. The teacher is not needed when a saved TPG runs.

### One decision, end to end

`Semantic-36` means **nine learned hosts × four response types**, not 36
concrete CAGE2 action IDs. The learned hosts are Defender, Enterprise0-2,
Op_Server0, and User1-4. GLOBAL/Monitor is a fallback, and User0 is outside
this teacher-derived 36-category vocabulary. Each current terminal learner
stores two categorical genes, `target` and `response`; its program still
computes a bid. For example:

```text
After the three fixed opening actions:
52 raw observation values + 10 scan-history values (0=unseen, 1=old, 2=latest)
    -> TPG ranks terminal learners by bid
    -> rank 0: (target=3 Enterprise1, response=3 DECOY)
       rank 1: (target=3 Enterprise1, response=0 ANALYSE)
    -> TPG semantic proposal: (Enterprise1, DECOY, option=NIL)
```

The `NIL` is deliberate: TPG has **not** chosen an Apache/Femitter/etc.
option. Suppose Enterprise1 is the only Decoy target in the bounded ranking
and its next scheduled option, `1` (Femitter), is unused. The B-line
Controller resolves the proposal to `(Enterprise1, DECOY, option=1)`, then
converts it to concrete CAGE2 action `43`. Only after that action actually
executes does it mark the option used. If the scheduled Enterprise1 Decoy is
already exhausted, the Controller tries the next ranked executable proposal:
`(Enterprise1, ANALYSE)` becomes concrete action `4`. If none works, it falls
back to GLOBAL/Monitor, concrete action `1`. With multiple Decoy targets in
the ranking, the global schedule may choose a different **proposed** target;
it cannot invent a Decoy target absent from the ranking.

The two terminal fields are genuinely mutable: changing only the response
gene from `(3, 0)` to `(3, 3)` changes a terminal from Enterprise1 Analyse to
Enterprise1 Decoy without changing its target. Ordinary instruction, learner,
team-edge, and graph mutations still operate too. A one-field gene edit does
**not** guarantee a one-state policy change; bidding and graph routing can
make its behavioral effect much wider, which is why locality is measured.

### One clean DAgger example

Suppose the learner visits an observation and proposes Enterprise1 Analyse,
while the heuristic proposes Enterprise1 Decoy. If the mixing controller
actually executes the learner's Analyse action `4`, that transition enters
the learner-visited training trace with the heuristic proposal as its label.
The unused Decoy is **not** marked used merely because the heuristic proposed
it. Scan history is updated from the next real observation. If mixing instead
executes the teacher's Decoy, only that executed Decoy updates the used-option
state. Thus the next label is queried against the history that actually
occurred, rather than a fictitious teacher-only history.

At selection time, a policy that is slightly worse on average imitation can
still be retained if it handles a critical target/response group well; that
is the purpose of grouped epsilon-lexicase. Multi-source nomination then
lets such a specialist, a behaviorally distinct policy, or a random control
receive official inspection. None wins a checkpoint merely by imitating the
teacher or entering a nomination lane: paired official return and fresh-seed
promotion remain the final decision.

## Training and selection

1. Use the deterministic Lisp heuristic for the selected opponent to label
   clean learner-visited trajectories. DAgger supplies on-policy examples;
   ranked semantic imitation supplies a learning signal without granting the
   teacher control over deployed actions.
2. Evolve the TPG with the `reduced-eq` instruction profile, categorical
   read-only registers, field-local instruction edits, effective-aware
   mutation, and bounded behavioral locality while retaining non-local
   exploration and ordinary learner/graph mutation.
3. Use grouped epsilon-lexicase to keep complementary behaviors in the
   population. Nominate aggregate, specialist, behaviorally distinct,
   critical-error, and random evolved candidates for official inspection.
4. Compare candidates on shared official episode seeds. Cheap admission is
   negative-only; one batch winner proceeds through fresh-seed staged
   confirmation. Only official promotion replaces the historical best.
   The saved best is an independent serialize/deserialize graph copy, written
   immediately after acceptance.
5. Freeze promising checkpoints and run independent official full validation
   at 30, 50, and 100 steps, with 1,000 episodes per horizon. Use fresh-root
   robustness evaluation for important comparisons.

Warm start intentionally reconstructs a new population around the protected
best rather than restoring a full population. Teacher imitation and mixed
rollout return are useful diagnostics, not substitutes for official promotion.

## Frozen results

Higher (less negative) reward is better. Each full-validation entry below is
from the official environment, 1,000 episodes at each horizon.

| Evolved checkpoint | 30 steps | 50 steps | 100 steps | Total |
| --- | ---: | ---: | ---: | ---: |
| [B-line v14](bline-v14/README.md) | -4.4237 | -7.8812 | -16.1792 | **-28.4841** |
| [Meander v8](meander-v8/README.md) | -5.5516 | -10.2254 | -23.6118 | **-39.3888** |

B-line v14 was evolved from a protected predecessor, not copied from the
compiled heuristic. Across eight fresh seed roots (800 B-line-100 episodes),
v14 scored `-16.4285 ± 0.2018 SE`; the compiled heuristic scored
`-16.3432 ± 0.1699 SE`. Their paired mean difference was
`-0.0853 ± 0.1516 SE`, so the robustness check places them at a similar level.

Meander v8 was evolved from a fresh heuristic-guided population. A separate
1,000-episode-per-horizon run of the current Lisp Meander heuristic scored
`-6.0179 / -10.6855 / -23.9295`, total `-40.6329`. V8's total mean was
`1.2441` higher, although its 50- and 100-step returns were more variable.
That comparison is recorded locally at
`/home/hardison/bes-artifacts/runtime/meander-online-return-baseline/teacher-comparison.md`;
the versioned v8 full-validation output is in
`meander-v8/full-validation-telemetry.log`.

The checkpoint files and their detailed provenance are in the two linked
subdirectories. These are validated starting points for subsequent work, not
a guarantee that every new stochastic training run will reproduce their
scores.

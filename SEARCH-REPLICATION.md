# Independent replication of the continuous-search B-line lineage

This experiment evaluates frozen policies only. It launches no evolution,
loads no teacher, and changes no Controller, official checkpoint or historical best.

## Motivation

The first continuous run made two B-line promotions under its existing >1-SE
criterion. Individual full-validation differences were +0.021 (SE 0.0180)
and +0.121 (SE 0.0704); neither had an unadjusted 95% interval above zero.
A fresh replication should precede increased search budgets or deployment.

The exact lineage has four states:
1. Initial automatically generated B-line expert, SHA cda3f1d75bde...
2. Random-lane conditional specialist parent, SHA a2bbd1b8a6a...
   It introduced Enterprise2 Decoy on two exact observable inputs, and had
   fresh-100 delta -0.040, SE 0.047. It was retained for bounded exploration.
3. First promotion, SHA b712f1e9a272...
   The same graph changes one atomic terminal from User4 Decoy to User4 Analyse.
4. Latest promotion, SHA 5191fa46ad98...
   The same graph changes one instruction in an Enterprise0 Analyse learner:
   (R1 ADD 20 0) becomes (R2 ADD 20 0). Since bidding uses zero-initialized R1
   under stateless execution, that learner's constant bid becomes 0 instead of 20.

These are verified genotype changes, not proof of their causal reward value.
The neutral parent and later promotions contain 1522 teams / 9843 learners,
compared with 1519 teams / 9824 learners in the initial graph.
Checkpoint loading reallocates IDs, so the audit compares canonical structural
slots, not raw runtime learner names.

## Frozen protocol

Four policies run on exactly the same fresh seed/horizon cases.
- Two predeclared independent seed roots: 202611182301 and 202611182302.
- Each root has 1000 episodes for each horizon 30, 50 and 100.
- Available historical request/plan seed records are conservatively excluded.
- Semantic-36, 62 inputs, fixed opening, fixed Cardiff global schedule and
  current Restore/Decoy Controller rules remain unchanged.
- Primary comparison: latest minus initial.
- Secondary comparisons: neutral minus initial, first minus neutral, latest
  minus first, first minus initial.
- Report paired differences, SE and 95% intervals by horizon, root and combined;
  absolute full totals, CVaR10, new/rescued < -100 episodes, per-host reward
  changes, Restore cost and first actual concrete-action divergence.
- The independent primary full-total 95% interval must exclude zero on the
  positive side before describing a confirmed mean improvement. Root consistency
  and adverse tails must be reviewed separately. No automatic promotion occurs.
- Incremental lineage comparisons do not establish that any intermediate edit
  was necessary. A reverse ablation would be needed to demonstrate necessity
  or reward-level epistasis.

Nominal official budget is exactly
2 roots * 1000 episodes * (30+50+100) steps * 4 policies = 1,440,000 transitions.
The completed engineering smoke consumed an additional 1,440 transitions, using
separate cases excluded from the final holdout. Six independent worker processes
own their SBCL/Python/environment instances. Jobs have 100 cases each; streaming
episode summaries avoid loading all trajectories into memory.

## Launch

    python3 -u scripts/replicate_search_lineage.py \
      --output /home/hardison/bes-artifacts/runtime/continuous-search-replication-20261118/full \
      --workers 6

The launcher redirects stdout to the parent directory's progress.log.
Monitor without polling this conversation:

    cd /home/hardison/bes-artifacts/runtime/continuous-search-replication-20261118
    tail -F progress.log

Each job writes returns.tsv, complete 62D paired trace.tsv and paired-episodes.jsonl.
The top-level full/plan.json freezes hashes, seeds, protocol and budget.
full/genotypes/report.json records exact graph changes.
full/results.json contains all comparisons; full/DONE marks completion.
A crash does not count as a completed experiment or trigger an automatic rerun
of partially collected evidence.


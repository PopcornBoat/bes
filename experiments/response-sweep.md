# Frozen response sweep for structural target/path gaps

The Level-2 matched screen found a target/path gap but its action-index tie
break selected a harmful response. This experiment tests every response for
each of the same five frozen Level-1 state/path groups. It does not choose a
response from the known User2 result, modify the incumbent, or synthesize a
specialist.

- Input: frozen gen-463 Meander checkpoint and the five state/path/target/host
  bit groups in `matched-counterfactual-lanes.sexp`. Ignore its structural and
  random action nominations.
- Fresh official seeds: `13000000 + 197*i`, `i=0..99`.
- For each seed and group, use the **first** nonopening incumbent state with
  the frozen terminal team and host bit tuple. Event selection does not inspect
  response availability, return, or candidate bids. Keep at most 40 distinct
  seed episodes per group in seed order.
- At that exact state, consider response indices 0=Analyse, 1=Remove,
  2=Restore, 3=Decoy for the frozen target. Resolve each with the canonical
  Controller. Record unavailable responses. An available response equal to
  the incumbent concrete action has zero delta without replay. For every
  other available response, replay and verify the whole prefix, replace one
  concrete action, and continue the unchanged incumbent to episode end.
- The first 20 eligible group episodes are the discovery cohort; the next 20
  form an untouched confirmation cohort. In discovery, nominate the response
  with the largest mean branch-minus-baseline full return among responses
  available in at least 15 episodes. Ties use response index. If none meets
  the minimum, make no nomination. Report the same fixed response on the
  confirmation cohort, including its availability and per-seed deltas.
- Report all four responses, available counts, intervention counts, actual
  official transition costs, and full-return deltas separately for both
  cohorts. A positive one-step intervention does not establish a deployable
  specialist. The known Meander/B-line cases are calibration only.

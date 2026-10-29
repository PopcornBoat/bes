# Independent Meander v8 gap screen

Run the unchanged target/path nomination algorithm on the validated Meander
v8 checkpoint, which was not the gen-463 positive-control parent used to
calibrate the response sweep. This is another previously studied policy,
not a wholly unseen policy population.

- Checkpoint: `validated-checkpoints/meander-v8/meander-62-36-v8.lisp`.
- Audit: `Cage2-meander-100-v0`, 100 seeds `16000000 + 197*i`.
- Apply `select-response-sweep-groups.py` unchanged: minimum 40 exposed
  episodes; one highest-score state/path group per target for five targets;
  same-target random group chosen by closest exposure and RNG 812731.
- If those prerequisites fail, record the failure before any intervention
  return is inspected; do not force five arbitrary groups into a structural
  comparison.
- If prerequisites pass, test all four response types in each frozen
  structural and random group on 100 fresh seeds `17000000 + 197*i`.
  Keep first 40 matching episode opportunities per group, with first 20
  for discovery and next 20 for confirmation. A response passes the screen
  only when the discovery choice has at least 15 available and 15 positive
  confirmation episodes with positive mean return.
- This remains a one-step official intervention. No specialist synthesis,
  formal training integration, or best-team promotion is authorized by the
  screen alone.

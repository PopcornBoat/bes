# Meander specialist warm start

The manually constructed User2 Restore positive control is frozen outside the
repository at `/home/hardison/bes-artifacts/frozen-checkpoints/meander-user2-restore-positive-control/candidate-1.lisp`.
Its SHA-256 is `98d7306a84bacacd16a11722833b0b25aab73c6b96b0fb684d97d6088afc7134`.
It was derived from the older gen-463 policy, not from Meander v8. It is a
diagnostic reference only and never enters this training population.

`scripts/run-meander-specialist-warmstart` starts with the protected v8 graph
(`52d6598e1cdd3b4839e60465cd67ab79e768125baa31522aec40ef485031afa3`).
The seven-lane nomination and its matched random controls are frozen from the
v8 official rollout. The runner screens all four responses on fresh seeds,
synthesizes ordinary TPG specialists without a hardcoded User2 action, and
uses the existing multi-candidate official admission plus an independent
fixed-candidate confirmation. Only an independently confirmed candidate is
queued for normal fresh-seed Stage-4 promotion at warm start. The historical
best remains v8 until that promotion actually succeeds. If no candidate
confirms, the normal official-guided search starts from v8 with no import.

This is a **one-time v8 discovery bootstrap** followed by ordinary
official-guided evolution. It does not continuously repeat gap discovery on
later incumbents. User2 Restore counts remain analysis-only. The experiment
tests whether the revised discovery and selection pathway can produce and
retain a useful specialist without importing the hand-built positive control.

The search uses its own TCP/UDP port 8081 and Emacs dashboard. Existing BES
sessions on the default 8080 port are untouched. The run directory stores
input hashes, response screen, incubation evidence, checkpoint, request, and
Emacs log. The name `v9` is reserved for a policy that actually passes
historical promotion and independent full validation.

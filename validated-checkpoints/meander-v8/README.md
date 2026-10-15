# Meander v8 validated checkpoint

`meander-62-36-v8.lisp` is the evolved Meander incumbent promoted as
official-guided version 8. It is a standalone Semantic-36 TPG policy trained
from the deterministic Lisp Meander heuristic through multi-lane official
admission; it does not contain or call the teacher at deployment time.

Policy configuration:

- checkpoint generation: `1777`
- recorded Meander-100 fitness: `-23.8928`
- 62 observations
- 36 `(target, response)` terminal actions
- stateless registers between environment steps
- fixed external decoy ordering with the Meander heuristic profile
- controller protocol `CAGE2-LISP-CONTROLLER-V2`
- checkpoint SHA-256:
  `52d6598e1cdd3b4839e60465cd67ab79e768125baa31522aec40ef485031afa3`

Official full validation over 1,000 episodes per horizon:

- Meander-30: mean `-5.5516`, standard deviation `1.4566`
- Meander-50: mean `-10.2254`, standard deviation `6.5280`
- Meander-100: mean `-23.6118`, standard deviation `12.4604`
- summed full score: `-39.3888`

The close agreement between the stored five-episode Meander-100 fitness and
the independent 1,000-episode Meander-100 mean indicates that this checkpoint's
100-step score was not a lucky short evaluation. `full-validation-telemetry.log`
contains the original validation output.

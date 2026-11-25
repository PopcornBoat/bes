# BLine v14 validated checkpoint

`bline-62-36-v14.lisp` is the evolved BLine incumbent promoted as official-guided
version 14. It is a standalone Semantic-36 TPG policy, not the compiled heuristic.

Policy configuration:

- 62 observations
- 36 `(target, response)` terminal actions
- stateless registers between environment steps
- fixed external decoy ordering
- controller protocol `CAGE2-LISP-CONTROLLER-V2`
- checkpoint SHA-256:
  `0d023ad8ad0f8191751e2a205b09c8bc5d3a15c2f17e1ca604ca0a3830fd0aa4`

Official full validation over 1,000 episodes per horizon:

- BLine-30: mean `-4.4237`, standard deviation `2.4138`
- BLine-50: mean `-7.8812`, standard deviation `3.1995`
- BLine-100: mean `-16.1792`, standard deviation `5.1365`
- summed full score: `-28.4841`

Independent robustness validation used eight fresh seed roots and 100 BLine-100
episodes per root (800 episodes total). V14 scored `-16.4285 ± 0.2018 SE`;
the compiled heuristic scored `-16.3432 ± 0.1699 SE`. The paired V14-minus-
compiled mean was `-0.0853 ± 0.1516 SE`.

`robustness-report.txt` is the readable report and
`robustness-summary.sexp` is the machine-readable result. The validation data
were produced by repository commit `476ff31152e6e53488b3fc811cbf3cd8b1a63a68`.

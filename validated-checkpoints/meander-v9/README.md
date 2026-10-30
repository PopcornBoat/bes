# Meander v9 validated checkpoint

`meander-62-36-v9.lisp` is the standalone Semantic-36 TPG promoted at generation 446 of the teacher-free official-online specialist run. It was warm-started from Meander v8. The first promotion in this run came from an automatically nominated and synthesized User2 Restore specialist; later official promotions came from aggregate and random-control candidates. The checkpoint does not require a teacher at deployment time.

Policy configuration:

- 62 observations (52 raw + 10 scan-state)
- 36 `(target, response)` terminal actions
- stateless registers between environment steps
- fixed Meander-specific external Decoy order and fixed opening
- controller protocol `CAGE2-LISP-CONTROLLER-V2`
- reduced-EQ instruction profile and categorical read-only registers
- checkpoint SHA-256: `27904a890c08c131fa8260e7619c7653e52dc9a768a19060b010dbdeb6b978a9`

Independent official full validation used random seed 153 and 1,000 episodes per horizon:

| Horizon | Mean | Standard deviation |
| --- | ---: | ---: |
| Meander-30 | -5.5782 | 1.3634 |
| Meander-50 | -8.9695 | 2.3097 |
| Meander-100 | -17.8195 | 12.0947 |
| Summed full score | **-32.3672** | |

The previous Meander v8 checkpoint scored `-39.3888` under the same validation configuration. The v9 gain is concentrated in the 50- and 100-step scenarios. Both evaluations start from seed 153; different policy actions can make subsequent environment RNG consumption diverge. The promotion audit recorded a full score of `-32.0348` on its own seed blocks. Validation on other seed roots remains a separate robustness check.

`full-validation-telemetry.log` contains the independent result. The original frozen checkpoint is retained at `/home/hardison/bes-artifacts/frozen-checkpoints/meander-active-specialist-20261029/historical-best-gen446.lisp`.

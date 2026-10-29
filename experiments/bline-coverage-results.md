# B-line v14 coverage fallback result

The originally frozen five-distinct-target structural/random comparison was
infeasible: the 100-episode official audit yielded only five high-exposure
eligible groups across four targets, with every structural score equal to
zero. The prereward fallback and exact groups were committed in `ccb4c3b`
before any substitute-action return was measured. This is a coverage scan,
not a test of structural nomination efficiency.

The response sweep used 100 fresh official B-line seeds beginning at
15,000,000. All five groups reached 40 distinct seed episodes, split into
20 discovery and 20 confirmation. Baselines cost 10,000 transitions and
intervention branches cost 65,200. Raw events are under
`/home/hardison/bes-artifacts/validations/bline-coverage-sweep-20261029/`.

| Group | Target and host bits | Discovery choice | Discovery mean delta | Confirmation mean delta |
| --- | --- | --- | ---: | ---: |
| 0 | Enterprise0 `0000` | Analyse | 0.000 | 0.000 |
| 1 | User3 `0000` | Analyse | 0.000 | 0.000 |
| 2 | Enterprise0 `1000` | Analyse | 0.000 | 0.000 |
| 3 | User2 `0000` | Analyse | 0.000 | 0.000 |
| 4 | User4 `0000` | Analyse | 0.000 | 0.000 |

No discovered response had positive confirmation mean. In the User2 group,
Restore averaged -0.865 in discovery and -1.000 in confirmation; Decoy was
Controller-unavailable at every matched state. The zero Analyse effects are
not positive repairs. In two groups Analyse equaled the incumbent concrete
action; in the others it changed the action but left the full return equal.

This is consistent with the previously observed failure of direct User2
Restore transfer to B-line, but it does not validate the structural score:
that score supplied no ordering signal for this checkpoint. Its immediate
reward loss-lift factor needs reconsideration before production integration.

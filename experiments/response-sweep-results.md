# Full response sweep on frozen Meander support gaps

The protocol and code were frozen in commit `3b74138` before the full run.
The frozen gen-463 Meander policy was unchanged. All four Semantic-36
responses were tested at the first matching official state for each of the
five previously identified `(host bits, terminal team, target)` groups.

## Integrity and budget

- Fresh seeds: `13000000 + 197*i`, `i=0..99`.
- Each group reached 40 distinct seed episodes. The first 20 formed the
  discovery cohort; the next 20 were held out for confirmation.
- 100 incumbent baseline episodes cost 10,000 transitions. Of 800 response
  slots, 748 required a replayed branch, costing 74,800 further official
  transitions. Responses were recorded as unavailable or identical to the
  incumbent where applicable.
- Every intervention replayed and verified its full pre-action official
  state and transition prefix. The Controller resolved each semantic response
  to a concrete action before execution.
- Event table SHA256:
  `bd560bd6e5e6b57cc97ac7f7a1ef52d536d9ff2f1000d3bee0ea71c4443849d8`.
  Local raw data and `analysis.json` are under
  `/home/hardison/bes-artifacts/validations/meander-response-sweep-20261029/`.

## Full-return effect of one replacement action

Each cell is the mean full-episode return difference relative to the
unchanged incumbent at the same official state and seed. Responses are
Analyse / Remove / Restore / Decoy. The bold response was chosen solely by
the discovery cohort's largest mean among responses available at least 15
times; the choice was then evaluated unchanged on the confirmation cohort.

| Group (terminal, target) | Cohort | Analyse | Remove | Restore | Decoy | Chosen |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| 0 (TEAM-0-33, User2 `0001`) | Discovery | -53.325 | -53.325 | **+5.515** | -0.045 | Restore |
| 0 | Confirmation | -37.060 | -37.060 | **+5.815** | -0.111 | Restore |
| 1 (TEAM-0-7, User3 `0001`) | Discovery | -0.110 | -7.165 | 0.000¹ | **+0.516** | Decoy |
| 1 | Confirmation | +0.130 | -7.405 | 0.000¹ | **-0.074** | Decoy |
| 2 (TEAM-0-7, Enterprise0 `0000`) | Discovery | +0.145 | +0.145 | -17.420 | **+0.244** | Decoy |
| 2 | Confirmation | -0.430 | -0.430 | -19.585 | **-0.658** | Decoy |
| 3 (TEAM-0-156, User2 `0001`) | Discovery | -50.700 | -50.700 | **+4.355** | -0.860 | Restore |
| 3 | Confirmation | -61.495 | -61.495 | **+4.895** | -2.650 | Restore |
| 4 (TEAM-0-7, User4 `0000`) | Discovery | **+0.250** | -0.080 | -0.670 | -0.619 | Analyse |
| 4 | Confirmation | **-0.055** | -0.055 | -1.055 | -0.115 | Analyse |

¹ User3 Restore resolved to the same concrete action as the incumbent on
all 40 opportunities. It cost no extra branch and its zero delta is not
evidence that a new Restore specialist would improve behavior. Decoy
availability ranged from 16 to 20 per 20-episode cohort; means above use
only available opportunities.

The selected User2 Restore effect remained positive on fresh confirmation
episodes: group 0 mean **+5.815**, positive on **20/20**; group 3 mean
**+4.895**, positive on **17/20**. The two groups may share seeds and should
not be treated as 40 independent confirmations. Other discovered choices
did not retain a positive mean on confirmation. In group 3 the Restore
effect also had three negative episodes, including a -15.3 worst case.

## Conclusion and boundary

Testing every response removes the action-index tie-break failure observed
in Level 2. On this known positive-control checkpoint, the procedure found
User2 Restore **without supplying that action to the selection rule**, and
the one-step effect replicated on fresh seeds. It did not find a stable
positive response in the other three groups.

This is still a *one-step intervention followed by the old policy*. It does
not establish a useful activation predicate or the full-return effect of a
heritable specialist that may fire repeatedly. The known User2 case cannot
demonstrate unbiased generalization. Further development should freeze a
predicate-synthesis and policy-validation protocol and test it on held-out
checkpoints; B-line supplies a useful negative-transfer check.

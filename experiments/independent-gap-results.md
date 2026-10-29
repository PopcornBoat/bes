# Independent gap screens: B-line v14 and Meander v8

The code and protocols were frozen before the official substitute-action
returns. Both checkpoints remained unchanged. The raw validation outputs
stay outside the repository under `/home/hardison/bes-artifacts/validations/`.

## B-line v14: no usable structural ranking signal

The 100-episode B-line audit produced only five groups with at least 40
independent episode exposures, across four targets. All five structural
scores were exactly zero because the immediate-reward loss-lift factor
vanished. The prereward fallback tested all five groups as a **coverage
scan**, not as a structural-vs-random comparison.

All groups reached 20 discovery plus 20 confirmation episodes on fresh
official seeds. No discovery-selected response had positive confirmation
mean. User2 Restore in the selected User2 `0000` group changed full return
by -0.865 in discovery and -1.000 in confirmation. The 100 baselines cost
10,000 transitions and the intervention branches 65,200. Full results are
in `bline-coverage-results.md`. Event SHA256:
`e64b71d6ad3f70fcf405308ecbc871d9d7f1aada404db747da42f75f441ae188`.

## Meander v8: structural and same-target random groups

An independent 100-episode audit found 33 eligible groups with at least 40
episode exposures. The frozen selection chose five distinct target groups
and, for each target, another eligible group with the closest audit exposure
as one random control. Only the first three structural groups had positive
structural scores; the User1 and Defender groups scored zero.

Both channels used the same fresh 100-seed block, `17000000 + 197*i`, and
all ten groups reached 20 discovery plus 20 confirmation opportunities.
Within each group, all four feasible responses were screened by single-step
official intervention followed by unchanged incumbent continuation.

| Target | Structural group: discovery choice | Structural confirmation mean; positive episodes | Random group: discovery choice | Random confirmation mean; positive episodes |
| --- | --- | ---: | --- | ---: |
| User2 | Restore | **+6.380; 20/20** | Restore | -9.005; 7/20 |
| User3 | Analyse | -0.585; 1/20 | Analyse | -0.110; 4/20 |
| User4 | Analyse | -0.250; 2/20 | Analyse | -0.420; 3/20 |
| User1 (zero-score) | Analyse | +0.325; 4/20 | Decoy | +0.825; 3/20 |
| Defender (zero-score) | Decoy | -0.840; 6/20 | Analyse | -5.415; 4/20 |

The preregistered screen required at least 15 available and 15 positive
confirmation episodes plus a positive mean. **Only the structural User2
Restore group passed.** This reproduces the known positive-control class
on another Meander checkpoint. It did not discover a new stable repair.
The zero-score groups' positive means above are driven by a few episodes,
not broad positive effects.

The structural channel used 10,000 baseline plus 72,600 branch transitions;
the random channel used 10,000 baseline plus 77,700 branch transitions.
Their group states differ, so same-seed results are not direct paired
structural-minus-random counterfactuals. Also, one random draw and unequal
actual transition costs do not establish superior discovery efficiency.
Structural event SHA256:
`0457dcf9aeffbbbb7f5e6dcdb13fb9b4fdbff5d899c456e1d93468ec6fad9834`.
Random event SHA256:
`a5dbef07dc7ef0c05649ecf85214855e6c16d629fe509f8707b71710c6eaf374`.

## Decision

Keep the method as a standalone experimental screen. It should **not yet
automatically inject candidates or replace best teams during online
training**. The known Meander repair is reproducible and the B-line negative
transfer was rejected, but the current structural score collapses on a
strong B-line policy and no new stable opportunity was found. Before
production use, replace or supplement the immediate-reward loss-lift with
a score that remains informative on strong policies, then freeze it and
test discovery yield on unseen checkpoints under matched official budgets.
Any confirmed one-step action still needs a learned TPG activation rule and
full-policy official validation before it can become a heritable repair.

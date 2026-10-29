# Active specialist incubation: Meander v8 pilot

The frozen source policy was `validated-checkpoints/meander-v8/meander-62-36-v8.lisp`
in `Cage2-meander-100-v0`. All official run artifacts, including raw per-seed
returns and SHA-256 input records, are under
`/home/hardison/bes-artifacts/validations/`.

| Step | Fresh seed block | Observation |
| --- | --- | --- |
| Structural audit | `18000000 + 197i`, 100 episodes | 168 eligible groups; 12 nominated across six structural lanes and matched random controls. No User2 target group was nominated. |
| Single-step response screen | `19000000 + 197i`, 100 baseline episodes | No group met the frozen 20-discovery/20-confirmation positive threshold. One structural and two random-control groups had positive discovery means and were retained as exploratory hypotheses. |
| Specialist incubation | Independent graph copies | Three hypotheses generated nine gate/insertion variants; all nine changed their positive probe and stayed within the background-change bound. |
| Common-seed admission | `20000000 + 197i` cheap, `20100000 + 197i` tournament | A random-control Enterprise2 Decoy variant was selected at `+0.805 ± 0.524` paired mean ± SE over 100 episodes. This was uncertain evidence, not a historical promotion. |
| Fixed-winner policy audit | `22000000 + 197i`, 20 episodes | Candidate minus incumbent: `+0.510 ± 1.138` paired mean ± SE; wins/losses/ties `8/10/2`. User2 Restore was selected zero times by both. |
| Independent fixed-winner confirmation | `26000000 + 197i` cheap, `26100000 + 197i` tournament | `−8.541 ± 8.818` over 100 paired episodes; wins/losses/ties `35/56/9`. The candidate is **not eligible** for population import or historical promotion. |

One confirmation seed (`26118518`) explains the large tail loss: incumbent
return `−19.5`, candidate return `−899.9`, paired delta `−880.4`. The policies
were in the same pre-action state at step 5. The inserted specialist changed
the action from Enterprise0 Decoy to Enterprise2 Decoy; later trajectories
diverged. On that candidate trajectory, Defender Remove was selected 78 times
from steps 3–99 and reward stayed at `−12.1` for much of the episode. This is
an observed failure path, not proof that the first different action alone
caused every later decision. With the worst seed excluded, the other 99 paired
episodes average `+0.266`, still too small to justify promotion.

The pilot shows that broad action-support nomination and local one-step
advantage can produce plausible TPG specialists, but a small observation gate
and a 20-state behavioral probe did not protect against long-horizon tail
risk. The response screen alone used 10,000 baseline and 173,700 intervention
transitions; the full pilot used about 320,300 official transitions across
all stages and confirmed zero improvements. The frozen positive-control soft
metric is zero: this run did not learn
User2 Restore. The next discovery experiment should improve state-group
coverage and collateral probes **without encoding the known User2 answer**,
then retain the independent fixed-candidate confirmation before inheritance.

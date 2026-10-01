# Semantic-36 Official-Guided Design

## Objective

The system studies how an evolutionary program policy can obtain stable,
local, cumulative improvement without gradients. It separates four concerns:

1. trajectory quality;
2. noisy candidate comparison;
3. genotype-to-behavior locality;
4. population-level specialist preservation.

## Policy and controller boundary

The TPG receives 62 inputs and produces a ranked list of direct Semantic-36
terminals. Each terminal identifies a target and response type. Concrete Decoy
options are not predicted by the TPG.

The controller owns:

- the fixed opening;
- scan-state maintenance;
- used-Decoy state;
- the global ordered Decoy schedule;
- executable-action resolution;
- concrete CAGE2 action conversion.

Proposal generation is pure. Controller state is committed only from the
concrete action that the environment executes.

## Training path

The deterministic heuristic labels teacher-controlled and learner-visited
states. Ranked imitation combines executable Top-1 agreement and ranking NDCG.
Every candidate in one generation sees the same sampled rows.

Behavioral-locality probes measure action and ranking disruption between each
parent and child. Mutation control bounds most outcomes but reserves explicit
unrestricted exploration. Grouped epsilon-lexicase then preserves candidates
that solve complementary target/response, trajectory, confidence, and failure
groups.

## Official comparison

Training, racing, promotion, and fixed monitoring use independent seed streams.
Candidates and incumbents share the same initial seeds within a racing round.
Fresh promotion blocks never reuse training or racing seeds. Early promotion
stages may reject but cannot promote. The final stage requires aggregate,
long-horizon, and tail-risk evidence.

The paired comparison is reproducible but not a perfect counterfactual: after
policies choose different actions, simulator branches may consume random values
differently.

## Checkpoint contract

The accepted best graph is saved immediately and copied through serialization
and deserialization so later population mutation cannot change it by reference.
Warm start loads that graph into a newly initialized population. It does not
restore the complete population or ordinary mutation state; that is deliberate
to control memory use and recover diversity.

Checkpoint metadata records the policy shape, teacher/controller protocol,
opening, observation prefix, action format, memory mode, and saved seed-stream
state where applicable. A legacy checkpoint without controller provenance may
be validated, but its old score is not assumed comparable under a new
controller protocol.

## Maintained and inactive mechanisms

The maintained path enables behavioral-locality measurement, bounded semantic
locality, grouped epsilon-lexicase, official paired racing, tail-aware staged
promotion, and Controller v2.

Targeted routing repair, specialist composition, teacher-directed repair,
return-credit lineages, and near-miss lineages remain available for historical
reproduction but are disabled by the active configuration because controlled
runs did not establish reliable official improvement.

# Maintained design

## Shared policy

Official CAGE2 supplies 52 raw observations. The Controller maintains ten scan-state values, giving the TPG 62 inputs. The TPG has 36 semantic target-response terminals. TPG traversal ranks the terminal proposals; the Controller resolves availability, uses its fixed global Decoy order, and updates state from the action actually executed. The final policy is a standalone serialized graph.

## Teacher-guided starting point

The offline DAgger workflow collects learner-visited traces with a deterministic Lisp heuristic teacher. Ranked semantic imitation and grouped epsilon-lexicase retain complementary policies. The official admission batch can nominate the aggregate leader, grouped specialists, behaviorally distinct policies, late-trajectory specialists, and random controls. Mixed return is diagnostic. Staged official evaluation on fresh seeds protects the historical best.

## Teacher-free online improvement

Online training starts from a protected best-team checkpoint. Every root is scored by official return on the same generation seed block. The ordinary admission batch can nominate the aggregate leader and random controls. In parallel, structural opportunity analysis nominates possible repairs and synthesizes conditional specialist offspring. Candidates with independent official evidence can join the population as bounded evidence anchors. Official racing and fresh paired seeds decide historical promotion.

The checkpoint saver deep copies the graph through serialization. Warm start deliberately reconstructs the population rather than loading a full population snapshot. Neither approach changes the deployed 62-input policy contract.

The maintained branches are `offline-dagger` and `online-official-specialists`. Historical experiments remain under archive refs and outside the active code path.

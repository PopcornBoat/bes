# Maintained design

## Shared policy

Official CAGE2 supplies 52 raw observations. The Controller maintains ten scan-state values, giving the TPG 62 inputs. The TPG has 36 semantic target-response terminals. A terminal winner supplies a ranked proposal; the Controller resolves availability, uses its fixed global Decoy order, and updates state from the action actually executed. The final policy is a standalone serialized graph.

## Teacher-guided starting point

The offline DAgger workflow collects learner-visited traces with a deterministic Lisp heuristic teacher. It uses ranked semantic imitation, behavioral locality checks and grouped epsilon-lexicase to retain complementary policies. Mixed return is diagnostic. Staged, fresh-seed official evaluation protects the historical best.

## Teacher-free online improvement

Online training starts from a protected best-team checkpoint. It generates evolved candidates without teacher labels. Multiple nomination lanes include aggregate, grouped specialist, behavioral diversity, critical state and random controls. Cheap official screening only rejects clear regressions. Promising candidates receive paired official racing and fresh-seed promotion. Structural opportunity analysis may nominate missing or suppressed actions and produce conditional specialist offspring; they still require independent official evidence.

The checkpoint saver deep copies the graph through serialization. Warm start deliberately reconstructs the population rather than loading a full population snapshot. Neither approach changes the deployed 62-input policy contract.

The maintained branches are `offline-dagger` and `online-official-specialists`. Historical experiments remain under archive refs and outside the active code path.

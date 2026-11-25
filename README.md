# Frozen incumbent v13

Saved candidate generation: 567. Search stopped normally at generation 1005.
Policy SHA256: `a4a8d0521a940952f70dd5b1f13941e25675dc43c086669b2ffe156a1c57899f`.

`bline-62-36-incumbent-v13.lisp` is byte-identical to the training best saved
on disk. It and the copied `.official-guided-state.lisp` are read-only.
`SHA256SUMS` also covers the experiment configuration. Revision files record
the BES and bridge code used at freeze time.

The journal is retained for provenance and seed-stream auditing. Warm-start
intentionally reconstructs the population; this is not a full process snapshot.
The journal's checkpoint filename remains the original training filename,
whereas the frozen policy has a shorter alias.

Run report and recoverable evidence archive:
`/home/hardison/bes-artifacts/archive/incumbent-conservative-gen1005-20261008/README.md`

Independent full-validation log:
`/home/hardison/bes-artifacts/runtime/incumbent-conservative-v13-validation/telemetry.log`

Final root-153 result: 30-step -4.5903, 50-step -8.8825, 100-step -19.4862,
total -32.9590; process exit code 0.

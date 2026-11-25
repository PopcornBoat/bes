# Frozen Enterprise0 and Defender combination

This release contains the native Controller, the B-line and Meander v15 expert graphs, and the TPG opponent classifier. The graphs retain their original hashes. The Controller uses the shared Enterprise0 option order 6, 2, 0, 7 and Defender order 7, 2, 0, 6. Decoy host selection follows Top-8 rank and the fixed opening is 51, 116, 55.

The full root 153 validation scored −56.6674 over 9,000 episodes and 540,000 official transitions. Zero episodes fell below −100. The worst B-line and Meander 100-step episodes were −34.8 and −39.0. The evidence directory preserves the validation manifest, official results, episode returns, log and raw-trace fingerprints.

The previous pure-graph release is preserved in the separate root153-decoy-order-best-20261123 directory. This release's score refers to the root 153 selection run.

## Verify and reproduce

Run sha256sum -c SHA256SUMS in this directory. Set BES_PYTHON_VENV and BES_ASDF_DEPENDENCIES to the pinned CybORG 2.1 virtual environment and Common Lisp library directory. Evaluate using the frozen assets and a fresh output path.

    "$BES_PYTHON_VENV/bin/python" -Bu validate.py /path/to/output --seed 153

#!/usr/bin/env python3
"""Compile an observation-ranked Semantic-36 catalogue into a standalone graph."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent


def lisp_string(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True, help="Pinned BES runtime and support bundle")
    parser.add_argument("--checkpoint", type=Path, required=True, help="Original fallback graph")
    parser.add_argument("--catalogue", type=Path, required=True, help="Trusted Lisp data file of (obs ranking) rows")
    parser.add_argument("--output", type=Path, required=True, help="New compiled checkpoint")
    parser.add_argument("--opponent", choices=("bline", "meander"), required=True)
    parser.add_argument("--legacy-counts", action="store_true", help="Use (obs counts ranking) rows")
    parser.add_argument("--meander-v15", action="store_true", help="Preserve the archived Meander v15 exception")
    parser.add_argument("--contexts", type=Path, help="Archived Lisp data of (cohort ((obs mask) ...)) rows")
    args = parser.parse_args()
    bundle = args.bundle.resolve(strict=True)
    source = args.checkpoint.resolve(strict=True)
    catalogue = args.catalogue.resolve(strict=True)
    contexts = lisp_string(args.contexts.resolve(strict=True)) if args.contexts else "nil"
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        parser.error("Output already exists")
    if args.meander_v15 and args.opponent != "meander":
        parser.error("--meander-v15 applies only to Meander")

    config = json.loads((bundle / "policy.json").read_text(encoding="utf-8"))
    with (bundle / "code/controller.lisp").open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != config["controller_sha256"]:
            parser.error("Bundle Controller differs from the pinned hash")
    explicit = os.environ.get("BES_ASDF_DEPENDENCIES")
    dependencies = ([Path(explicit)] if explicit else [
        Path.home() / "quicklisp/local-projects",
        Path.home() / "quicklisp/dists/quicklisp/software",
    ])
    trees = " ".join(f"(:tree {lisp_string(str(path) + '/')})" for path in dependencies if path.is_dir())
    registry = f'(:source-registry (:directory {lisp_string(str(bundle / "code") + "/")}) {trees} :ignore-inherited-configuration)'
    command = ["sbcl", "--noinform", "--non-interactive", "--eval", "(require :asdf)",
               "--eval", "(asdf:load-system :cl-tpg)"]
    for path in (bundle / "support/standalone-runtime.lisp", bundle / "support/00-post-opening-router.lisp",
                 bundle / "support/01-expert-dispatch.lisp", HERE / "ranked-graph.lisp", HERE / "compile-routes.lisp"):
        command += ["--load", str(path)]
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".compile-routes-", dir=output.parent) as tmp:
        compiled = Path(tmp) / "graph.lisp"
        shape = ":legacy-counts" if args.legacy_counts else ":observation"
        policy = ":meander-v15" if args.meander_v15 else ":standard"
        form = (f"(cl-tpg::compile-route-catalogue {lisp_string(source)} {lisp_string(catalogue)} "
                f"{lisp_string(compiled)} :{args.opponent}-cardiff-global {shape} {policy} {contexts})")
        subprocess.run([*command, "--eval", form], cwd=bundle / "code", check=True,
                       env={**os.environ, "CL_SOURCE_REGISTRY": registry})
        # Link atomically to refuse a concurrent output with the same name.
        os.link(compiled, output)


if __name__ == "__main__":
    main()

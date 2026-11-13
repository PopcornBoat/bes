#!/usr/bin/env python3
"""Export the source-only Docker context from locally pinned dependencies."""
import argparse
import hashlib
import io
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

REPO = Path(__file__).resolve().parents[1]


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args])


def export(repo, paths, destination):
    destination.mkdir(parents=True)
    content = git(repo, "archive", "HEAD", *paths)
    with tarfile.open(fileobj=io.BytesIO(content)) as source:
        source.extractall(destination, filter="data")


def bundle(bridge, cyborg, lisp_sources, output):
    with tempfile.TemporaryDirectory(prefix="bes-docker-") as temp:
        context = Path(temp)
        tracked = git(REPO, "ls-files").decode().splitlines()
        sources = [path for path in tracked if "/" not in path and path.endswith(".lisp")]
        sources += ["cl-tpg.asd", "cardiff_env.py", "LICENSE", "agreements", "scripts",
                    "tests/cardiff-action-space.lisp", "tests/controller.lisp",
                    "experiments/active-specialist-incubation.md"]
        export(REPO, sources, context / "bes")
        export(REPO, ["docker"], context / "bes-docker-export")
        (context / "bes-docker-export/docker").rename(context / "bes/docker")
        (context / "bes-docker-export").rmdir()
        package = "cage2_bridge/cage2_bridge"
        export(bridge, [f"{package}/pyproject.toml", f"{package}/src/cage2_bridge"],
               context / "bridge-export")
        (context / "bridge-export" / package).rename(context / "bridge")
        shutil.rmtree(context / "bridge-export")
        export(cyborg, ["CybORG"], context / "cyborg-export")
        (context / "cyborg-export/CybORG").rename(context / "CybORG")
        shutil.rmtree(context / "cyborg-export")
        for directory in ("bridge", "CybORG"):
            for path in (context / directory).rglob("*"):
                if path.is_file() and path.suffix.lower() in {".npz", ".pth", ".pt", ".onnx", ".pkl"}:
                    path.unlink()
        shutil.copytree(lisp_sources, context / "lisp",
                        ignore=shutil.ignore_patterns(".git", ".config", "*.fasl"))
        for name in ("Dockerfile", "requirements.lock"):
            shutil.copy2(REPO / "docker" / name, context / name)
        files = ("Dockerfile", "requirements.lock", "bes/docker/meander.py",
                 "bes/cardiff_env.py", "bes/networking.lisp")
        manifest = [f"{label} {git(path, 'rev-parse', 'HEAD').decode().strip()}"
                    for label, path in (("BES base", REPO), ("Bridge", bridge), ("CybORG", cyborg))]
        manifest.append("Lisp sources " + ", ".join(sorted(p.name for p in lisp_sources.iterdir())))
        manifest.extend(f"{hashlib.sha256((context / name).read_bytes()).hexdigest()}  {name}"
                        for name in files)
        (context / "source-manifest.txt").write_text("\n".join(manifest) + "\n")
        with tarfile.open(output, "w:gz") as target:
            for path in sorted(context.iterdir()):
                target.add(path, arcname=path.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge", type=Path, required=True)
    parser.add_argument("--cyborg", type=Path, required=True)
    parser.add_argument("--lisp-sources", type=Path, required=True)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    bundle(args.bridge, args.cyborg, args.lisp_sources, args.output)


if __name__ == "__main__":
    main()

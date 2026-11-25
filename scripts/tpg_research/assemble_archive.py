#!/usr/bin/env python3
"""Build the fixed final-report evidence index and replay inputs."""
import argparse
from pathlib import Path
import json
import shutil
import subprocess
import sys
from visualize_tpg import dump, sha

REPO = Path(__file__).resolve().parents[2]


def make(artifacts, out, repo):
    frozen = artifacts/"frozen-checkpoints/root153-e0-defender-combined-20261123"
    runtime = artifacts/"runtime"
    remote = runtime/"final-research-archive-20261124"
    out.mkdir(parents=True,exist_ok=False)
    evidence = out/"evidence"
    evidence.mkdir()
    code = out/"code"
    code.mkdir()
    for path in Path(__file__).parent.iterdir():
        if path.suffix in (".py",".lisp",".md"):
            shutil.copyfile(path,code/path.name)
    manifest = json.loads((frozen/"policy.json").read_text())
    for file in ("policy.json","README.md","SHA256SUMS"):
        shutil.copyfile(frozen/file,evidence/("frozen-"+file))
    shutil.copytree(frozen/"evidence",evidence/"frozen-root153")
    for name in ("one-shot","graph-restore"):
        shutil.copytree(remote/name,evidence/name)
    for file in ("archive-coverage.json","separability.json","plan.json"):
        shutil.copyfile(remote/"preimpact"/file,evidence/("preimpact-"+file))
    d = runtime/"full-agent-validation-20261120"
    shutil.copyfile(d/"manifest.json",evidence/"cardiff-reference-manifest.json")
    shutil.copyfile(d/"full/cardiff/results.json",evidence/"cardiff-reference-results.json")
    d = artifacts/"frozen-checkpoints/root153-decoy-order-best-20261123"
    shutil.copyfile(d/"validation-evidence.json",evidence/"previous-controller-validation.json")
    trace_origin = json.loads((frozen/"evidence/trace-origin.json").read_text())
    assert sha(remote/"final-root153/actions.tsv")==trace_origin["trace_sha256"]["actions.tsv"]
    decisions_path = evidence/"final-root153-actions.tsv"
    shutil.copyfile(remote/"final-root153/actions.tsv",decisions_path)
    indices = {}
    def register(name, checkpoint, traces, task):
        digest = sha(checkpoint)
        assert all(Path(s["path"]).is_file() for s in traces)
        for source in traces:
            source["checkpoint_sha256"] = digest
            source["source_sha256"] = sha(source["path"])
        dump(evidence/(name+"-traces.json"),traces)
        indices[name] = {"checkpoint":str(checkpoint), "sha256":digest,
                         "traces":str(evidence/(name+"-traces.json")),"scope":task}
    def raw(path,fmt,task,**fields):
        return {"path":str(path),"format":fmt,"task":task,**fields}
    assets = {k:frozen/"inputs"/v["file"] for k,v in manifest["input_sha256"].items()}
    assert all(sha(p)==manifest["input_sha256"][k]["sha256"] for k,p in assets.items())

    b_sources = []
    for directory, cohort in (("bline-restore-root153-20261116/full","153-explicit"),
                              ("bline-balanced-action-credit-20261115/replication-baseline-1","replication-1"),
                              ("bline-balanced-action-credit-20261115/replication-baseline-2","replication-2")):
        for path in sorted((runtime/directory).glob("worker-*/trace.tsv")):
            b_sources.append(raw(path,"worker","B-line",arm="baseline",cohort=cohort,
                                 profile=":bline-cardiff-global",resolution=":profile",horizons=[100],
                                 protocol="historical expert replay; independent explicit episode seeds"))
    assert len(b_sources) > 0
    register("final-bline",assets["b_line"],b_sources,"final B-line graph; archived expert protocol")

    m_sources = []
    for d in sorted((remote/"preimpact").glob("root-*")):
        data = json.loads((d/"manifest.json").read_text())
        assert data["bes_inputs"]["meander"]["sha256"]==sha(assets["meander"])
        assert data["controller_sha256"]==manifest["controller_sha256"]
        assert data["table"]==manifest["table"]
        m_sources.append(raw(d/"episodes.jsonl.gz","preimpact","Meander",profile=":meander-cardiff-global",
                             resolution=":ranked-decoy-hosts",protocol="final controller, single continuous Meander / 100-step cell"))
    assert len(m_sources)==10
    register("final-meander",assets["meander"],m_sources,"final Meander graph, ten fresh roots")

    router = runtime/"bes-opponent-router-20261116/retest-2026111601"
    true_router = json.loads((router/"results.json").read_text())
    assert true_router["checkpoint_sha256"]==sha(assets["router"])
    shutil.copyfile(router/"results.json",evidence/"router-retest-results.json")
    register("final-router",assets["router"],[
        raw(router/"observations.tsv","router",task,label=label,cohort=true_router["seed_root"],
            protocol="same frozen classifier; first three fixed opening actions; labels are the task")
        for task,label in (("B-line","bline"),("Meander","meander"),("Sleep","sleep"))
    ],"shared three-task opening classifier; atomic outputs are class labels")

    for name, task, directory, asset, profile in (
        ("bline-v14","B-line","bline-full-paired-validation-20261104","bline-62-36-v14.lisp",":heuristic"),
        ("meander-v9","Meander","meander-v9-full-paired-20261105","meander-62-36-v9.lisp",":meander-heuristic"),
    ):
        checkpoint = repo/"validated-checkpoints"/name/asset
        traces = []
        for seed in (153,42):
            directory_path = runtime/directory/f"root-{seed}"
            assert sha(checkpoint) in (directory_path/"input-sha256.txt").read_text()
            traces.append(raw(directory_path/"trace.tsv","paired",task,
                              profile=profile,resolution=":profile",
                              protocol="historical native paired expert evaluation; explicit episode seeds"))
            shutil.copyfile(directory_path/"returns.tsv",evidence/f"{name}-root{seed}-returns.tsv")
        register(name,checkpoint,traces,"historical expert only; archived protocol and sample size differ")

    graph_candidate = runtime/"meander-graph-restore-20261124/meander-graph-restore.lisp"
    candidate_manifest = json.loads((runtime/"meander-graph-restore-20261124/bundle/candidate.json").read_text())
    assert candidate_manifest["sha256"]==sha(graph_candidate)
    register("meander-restore-graph",graph_candidate,[],
             "pure graph restore candidate; official outcomes archived, full per-step input absent")

    dump(out/"archive-index.json",{
        "final_score":-56.6674,"original_release":str(frozen),"new_official_transitions":0,
        "frozen_policy":manifest,"code":str(frozen/"code"),"checkpoints":indices,
        "reference":"Nov 20 Cardiff 90000 full validation is an external comparator only.",
        "excluded_from_checkpoint_comparisons":["external one-shot guard","runtime observation-action tables"],
        "source_gap":"Official root 153 action log has no per-step observations or contender paths.",
    })


if __name__ == "__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--artifacts",type=Path,required=True)
    p.add_argument("--output",type=Path,required=True)
    p.add_argument("--repo",type=Path,default=REPO)
    args=p.parse_args()
    make(args.artifacts,args.output,args.repo)

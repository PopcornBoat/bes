"""Validate one-shot recognizer dispatch of frozen automatic TPG experts."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import random
import statistics
import subprocess
from continuous_official_search import (
    REPO, BACKEND, digest, save, rows, number, sexp, write_sexp, evaluate_job, VENV)
import os
ROOT=Path.home()/"bes-artifacts/runtime"
SOURCES={
    "router":ROOT/"bes-opponent-router-20261116/opponent-router.lisp",
    "b_line":ROOT/"window-repair-full-validation-20261118/inputs/b_line/auto-f3ad4823d3.lisp",
    "meander":ROOT/"window-repair-full-validation-20261118/inputs/meander/e2-analyse.lisp"}
HASHES={
    "router":"8864b37e6b3a80536cf2246df508182a3adc849e16cfb37e2e143bd3da87c834",
    "b_line":"cda3f1d75bdec6a6622974af492d4396753f427619d41afcd93d3509a9e12994",
    "meander":"3b9c6a4f11ffdbc28551c3eb65201a333b4ce8c8f2b8ad225659c6ee22459010"}
def worker(red,h,cases,root,smoke):
    folder=root/f"{red}-{h}"
    folder.mkdir(exist_ok=True)
    output=folder/"episodes.tsv"
    if not (folder/"complete.json").exists():
        output.unlink(missing_ok=True)
        write_sexp(folder/"requests.sexp",list(enumerate(cases)))
        args=[*(str(SOURCES[k]) for k in ("router","b_line","meander")),
              red,h,str(folder/"requests.sexp"),str(output)]
        form="(cl-tpg::dispatch-full-cell "+" ".join(sexp(a) for a in args)+\
             " :bline-profile :bline-cardiff-global :meander-profile :meander-cardiff-global)"
        command=["sbcl","--dynamic-space-size","1536","--noinform","--non-interactive",
                 "--eval","(require :asdf)","--eval","(asdf:load-system :cl-tpg)"]
        for name in ("post-opening-router.lisp","expert-dispatch.lisp"):
            command+=["--load",str(REPO/"scripts"/name)]
        command+=["--eval",form]
        env=dict(os.environ,PYTHONHASHSEED="0",OPENBLAS_NUM_THREADS="1",OMP_NUM_THREADS="1",
                 MKL_NUM_THREADS="1",CUDA_VISIBLE_DEVICES="-1",
                 CL_SOURCE_REGISTRY=f'(:source-registry (:directory "{REPO}/") :ignore-inherited-configuration)')
        env["PATH"]=str(VENV/"bin")+os.pathsep+env["PATH"]
        with (folder/"worker.log").open("w") as f:
            subprocess.run(command,cwd=REPO,env=env,stdout=f,stderr=subprocess.STDOUT,check=True)
    data=list(rows(output))
    assert len(data)==len(cases)
    expected={"b_line":"b-line","meander":"meander","sleep":"sleep"}[red]
    assert all(r["route"]==expected and int(r["steps"])==h for r in data)
    if smoke:
        if red=="sleep":
            assert all(abs(number(r["return"]))<1e-9 for r in data)
        else:
            paired=evaluate_job(red,folder/"direct",[(h,s) for s in cases],{"expert":SOURCES[red]})
            direct={int(r["seed"]):number(r["return"]) for r in rows(paired/"returns.tsv")}
            actions={}
            for r in rows(paired/"trace.tsv"):
                actions.setdefault(int(r["seed"]),[]).append(int(r["concrete"]))
            for r in data:
                seed=int(r["seed"])
                assert abs(number(r["return"])-direct[seed])<1e-7
                assert list(map(int,r["actions"].split(",")))==actions[seed]
    scores=[number(r["return"]) for r in data]
    result=dict(n=len(scores),mean=statistics.mean(scores),std=statistics.stdev(scores) if len(scores)>1 else 0,
                minimum=min(scores),recognition_errors=0,transitions=h*len(scores)*(2 if smoke and red!="sleep" else 1))
    save(folder/"complete.json",result)
    print(f"DONE {red}-{h} n={len(scores)} mean={result['mean']:.6f}",flush=True)
    return f"{red}-{h}",result
def main():
    p=argparse.ArgumentParser();p.add_argument("--output",required=True);p.add_argument("--smoke",action="store_true")
    p.add_argument("--workers",type=int,default=3);a=p.parse_args()
    root=Path(a.output);root.mkdir(parents=True,exist_ok=True)
    assert {k:digest(v) for k,v in SOURCES.items()}==HASHES
    count=1 if a.smoke else 1000
    rng=random.Random(202611181944)
    cells=[(red,h,rng.sample(range(1_500_000_000+h*100_000,1_500_000_000+h*100_000+99000),count))
           for red in ("b_line","meander","sleep") for h in (30,50,100)]
    plan=dict(hashes=HASHES,smoke=a.smoke,cells=cells,transitions=sum(h*len(s)*(2 if a.smoke and r!="sleep" else 1) for r,h,s in cells))
    save(root/"plan.json",plan)
    with ThreadPoolExecutor(max_workers=a.workers) as pool:
        results=dict(pool.map(lambda c:worker(*c,root,a.smoke),cells))
    save(root/"results.json",dict(cells=results,total=sum(c["mean"] for c in results.values()),
                                transitions=sum(c["transitions"] for c in results.values())))
    print("DONE full recognizer-dispatch validation",flush=True)
if __name__=="__main__":
    main()


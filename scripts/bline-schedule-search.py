#!/usr/bin/env python3
"""Race B-line global schedule permutations with a frozen v14 graph."""
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
import csv
import hashlib
from itertools import permutations
import json
import os
from pathlib import Path
import random
from statistics import mean
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parent.parent
VENV = Path("/home/hardison/venv-base/cage2_bridge/.venv/bin")
CHECKPOINT = REPO / "validated-checkpoints/bline-v14/bline-62-36-v14.lisp"
V14 = "0d023ad8ad0f8191751e2a205b09c8bc5d3a15c2f17e1ca604ca0a3830fd0aa4"
BASE = ((8,1),(8,6),(2,2),(3,1),(4,1),(2,6),(2,7),(5,2),(5,6),(5,0),(9,7),(9,4),(5,7),(10,7))
HOSTS = tuple(dict.fromkeys(host for host,_ in BASE))
WORKERS = 8
STAGES = (
    ("screen", ((30,3),), 256),
    ("race", ((30,8),(50,8)), 32),
    ("long", ((100,24),), 4),
    ("confirm", ((30,100),(50,100),(100,100)), 1),
)

def host_options(schedule):
    return {host:tuple(option for target,option in schedule if target == host) for host in HOSTS}

def catalogue():
    order = host_options(BASE)
    schemes = {BASE:"original"}
    for permutation in permutations(HOSTS):
        block = tuple((host,option) for host in permutation for option in order[host])
        schemes.setdefault(block,"host-block")
    for i, entry in enumerate(BASE):
        without = BASE[:i] + BASE[i+1:]
        for j in range(len(BASE)):
            candidate = without[:j] + (entry,) + without[j:]
            if host_options(candidate) == order:
                schemes.setdefault(candidate,"local-interleaving")
    rows = [{"id":i,"schedule":s,"family":family} for i,(s,family) in enumerate(schemes.items())]
    assert len({tuple(r["schedule"]) for r in rows if r["family"]=="host-block"}) == 5040
    assert all(host_options(r["schedule"])==order for r in rows)
    return rows

def request(path, samples, jobs):
    episodes = " ".join(f"({h} {seed})" for h,seed in samples)
    rows = []
    for r in jobs:
        entries = " ".join(f"({h} {opt})" for h,opt in r["schedule"])
        rows.append(f'({r["id"]} ({entries}))')
    path.write_text(f"(({episodes}) (\n"+"\n".join(rows)+"\n))\n")

def lisp_environment():
    environment = dict(os.environ)
    environment["PATH"] = str(VENV)+os.pathsep+environment["PATH"]
    environment["CL_SOURCE_REGISTRY"] = f'(:source-registry (:directory "{REPO}/") :ignore-inherited-configuration)'
    environment["OPENBLAS_NUM_THREADS"] = "1"
    environment["OMP_NUM_THREADS"] = "1"
    return environment

def run_worker(folder, index, samples, jobs):
    input_path = folder/f"worker-{index}.sexp"
    output = folder/f"worker-{index}.tsv"
    request(input_path,samples,jobs)
    args = [json.dumps(str(p)) for p in (CHECKPOINT,input_path,output)]
    environment = lisp_environment()
    command = ["sbcl","--dynamic-space-size","2048","--noinform","--non-interactive",
               "--eval","(require :asdf)","--eval","(asdf:load-system :cl-tpg)",
               "--load",str(REPO/"scripts/bline-schedule-search.lisp"),
               "--eval","(cl-tpg::run-bline-schedule-worker "+" ".join(args)+")"]
    with (folder/f"worker-{index}.log").open("w") as log:
        subprocess.run(command,cwd=REPO,env=environment,stdout=log,stderr=subprocess.STDOUT,check=True)

def measure(folder, name, samples, candidates):
    folder.mkdir()
    workers = min(WORKERS,len(candidates))
    start = time.monotonic()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        pending = [pool.submit(run_worker,folder,i,samples,candidates[i::workers]) for i in range(workers)]
        while not all(job.done() for job in pending):
            for job in pending:
                if job.done():
                    job.result()
            count = sum(len(f.read_bytes().splitlines()) for f in folder.glob("worker-*.tsv"))
            print(f"current  {name:<8} {count:>5}/{len(candidates)} tables  {time.monotonic()-start:.0f}s",flush=True)
            time.sleep(10)
        for job in pending:
            job.result()
    data = {}
    for f in folder.glob("worker-*.tsv"):
        with f.open() as stream:
            for raw in csv.reader(stream,delimiter="\t"):
                key = int(raw[0])
                assert key not in data and len(raw)==1+len(samples)
                data[key] = [float(v) for v in raw[1:]]
    assert set(data)=={r["id"] for r in candidates}
    return data

def summarize(samples, scores):
    grouped = defaultdict(list)
    for (h,_),v in zip(samples,scores):
        grouped[h].append(v)
    return {"objective":sum(mean(values) for values in grouped.values()),
            "means":{h:mean(values) for h,values in grouped.items()},
            "worst":{h:min(values) for h,values in grouped.items()},
            "below_minus_100":sum(v < -100 for v in scores)}

def run(out, smoke):
    assert hashlib.sha256(CHECKPOINT.read_bytes()).hexdigest()==V14
    out.mkdir(parents=True,exist_ok=True)
    with (out/"compile.log").open("w") as log:
        subprocess.run(["sbcl","--noinform","--non-interactive","--eval","(require :asdf)",
                        "--eval","(asdf:load-system :cl-tpg)"],cwd=REPO,env=lisp_environment(),
                       stdout=log,stderr=subprocess.STDOUT,check=True)
    rows = catalogue()
    (out/"catalogue.json").write_text(json.dumps(rows,separators=(",",":"))+"\n")
    print(f"current  {len(HOSTS)} eligible hosts  {len(rows)} tables  {WORKERS} workers",flush=True)
    print("current  frozen B-line v14  official CybORG rollouts",flush=True)
    rng = random.Random(921735)
    current = rows[:8] if smoke else list(rows)
    rng.shuffle(current)
    stages = (("smoke",((30,1),),1),) if smoke else STAGES
    used_seeds = set()
    best = None
    for name,spec,limit in stages:
        samples = []
        for h,n in spec:
            for _ in range(n):
                seed = rng.randrange(100000000,200000000)
                while seed in used_seeds:
                    seed = rng.randrange(100000000,200000000)
                used_seeds.add(seed)
                samples.append((h,seed))
        folder = out/name
        active = [rows[0],*(r for r in current if r["id"]!=0)]
        scores = measure(folder,name,samples,active)
        metrics = {r["id"]:summarize(samples,scores[r["id"]]) for r in active}
        order = sorted(active,key=lambda r:metrics[r["id"]]["objective"],reverse=True)
        best = order[0]
        baseline = metrics[0]["objective"]
        details = {"samples":samples,"transitions":sum(h for h,_ in samples)*len(active),
                   "metrics":metrics,"best":best,"rank":[r["id"] for r in order]}
        (folder/"results.json").write_text(json.dumps(details,indent=2)+"\n")
        print(f"current  {name} complete  best table {best['id']}  baseline {baseline:.3f}  "
              f"candidate {metrics[best['id']]['objective']:.3f}  delta {metrics[best['id']]['objective']-baseline:+.3f}",flush=True)
        if name=="screen":
            # Reserve slots for nearby interleavings and distribute exact-score ties.
            close = [r for r in order if r["family"]=="local-interleaving"][:32]
            keep = {r["id"] for r in close}
            current = close+[r for r in order if r["id"] not in keep and r["id"]!=0][:limit-len(close)]
        else:
            current = [r for r in order if r["id"]!=0][:limit]
    schedule = " ".join(f"({h} {o})" for h,o in best["schedule"])
    (out/"best-schedule.sexp").write_text(f"({schedule})\n")
    (out/"DONE").write_text(f"Completed {len(stages)} stages; best table {best['id']}.\n")
    print(f"current  DONE  best table {best['id']}",flush=True)

if __name__ == "__main__":
    run(Path(sys.argv[1]).resolve(),sys.argv[2:]==["--smoke"])

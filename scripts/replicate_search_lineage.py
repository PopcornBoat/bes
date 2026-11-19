"""Read-only paired holdout replication of an automatically discovered lineage.

Four frozen policies, two independently seeded 1000-episode blocks at each of
30/50/100 steps. The primary comparison is latest versus the initial policy.
No selection, mutation, teacher, deployment or historical-best writes occur.
"""
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
import argparse
import csv
import hashlib
from itertools import groupby
import json
import math
from pathlib import Path
import random
import re
import shutil
import statistics
import subprocess
import time
from continuous_official_search import REPO, digest, evaluate_job, rows, number, run_lisp, save, read, sexp, stats

RUNTIME=Path.home()/"bes-artifacts/runtime"
SEARCH=RUNTIME/"continuous-official-search-20261118/b_line"
MODELS={
    "baseline":(SEARCH/"initial.lisp","cda3f1d75bdec6a6622974af492d4396753f427619d41afcd93d3509a9e12994"),
    "neutral":(SEARCH/"cycle-0000/offspring/c0000-07-8b2565e565e9/c0000-07-8b2565e565e9.lisp","a2bbd1b8a6ae3a9172b2ce088a5bfd0fb70f4c9a62d56f78a53c0a09a9b91809"),
    "first":(SEARCH/"cycle-0001/offspring/c0001-09-native-9/c0001-09-native-9.lisp","b712f1e9a272fdea9a1a721fe3eeed8c3102bde0c7d2189236b2bb1ff96edb63"),
    "latest":(SEARCH/"cycle-0003/offspring/c0003-08-native-8/c0003-08-native-8.lisp","5191fa46ad986c91bb16eccbcb351a22e1d342ec01360c52848a2b4099678890"),
}
HORIZONS=(30,50,100)
ROOTS=(202611182301,202611182302)
COMPARISONS=(("neutral","baseline"),("first","neutral"),("latest","first"),
             ("first","baseline"),("latest","baseline"))

def log(root,event,**values):
    line=time.strftime("%Y-%m-%d %H:%M:%S")+" "+event+" "+" ".join(f"{k}={v}" for k,v in values.items())
    print(line,flush=True)
    with (root/"events.jsonl").open("a") as f:
        f.write(json.dumps(dict(time=time.time(),event=event,**values),sort_keys=True)+"\n")

def frozen(root):
    folder=root/"inputs";folder.mkdir(exist_ok=True)
    result={}
    for label,(source,checksum) in MODELS.items():
        assert digest(source)==checksum
        target=folder/(label+".lisp")
        if not target.exists():
            shutil.copyfile(source,target);target.chmod(0o444)
        assert digest(target)==checksum
        result[label]=target
    return result

def genotype_audit(root,models):
    output=root/"genotypes";output.mkdir(exist_ok=True)
    tables={}
    for label,path in models.items():
        exported=output/(label+".tsv")
        if not exported.exists():
            form="(progn (load "+sexp(str(REPO/"scripts/search-lineage-audit.lisp"))+") "+\
                 "(cl-tpg::continuous-lineage-export \"b_line\" "+sexp(str(path))+" "+sexp(str(exported))+"))"
            run_lisp(form,output/(label+"-export"))
        tables[label]={(r["node"],r["slot"]):r for r in rows(exported)}
    comparisons={}
    for child,parent in COMPARISONS:
        a,b=tables[parent],tables[child]
        common=a.keys()&b.keys()
        # Canonical slots support exact comparison only for topology-identical pairs.
        same_topology=(a.keys()==b.keys() and all(a[k]["action_kind"]==b[k]["action_kind"]
                       and (a[k]["action_kind"]!="REFERENCE" or a[k]["action"]==b[k]["action"]) for k in common))
        changes=[]
        if same_topology:
            for key in sorted(common,key=lambda k:tuple(map(int,k))):
                for field in ("action","program"):
                    if a[key][field]!=b[key][field]:
                        changes.append(dict(node=int(key[0]),slot=int(key[1]),field=field,
                                            before=a[key][field],after=b[key][field]))
        comparisons[child+"-"+parent]=dict(same_topology=same_topology,changes=changes,
             note="Canonical graph slots; runtime IDs are not stable across checkpoint loading.")
    result=dict(policies={k:dict(teams=len({r["node"] for r in t.values()}),learners=len(t))
                          for k,t in tables.items()},comparisons=comparisons)
    save(output/"report.json",result)
    return result

def previous_seeds(root):
    """Conservative exclusion of numeric seeds found in archived request/plan files."""
    command=["rg","--files",str(RUNTIME)]
    for pattern in ("plan.json","*seed*.json","requests.sexp","cases.sexp","request.json","state.json"):
        command+=["-g",pattern]
    result=subprocess.run(command,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True)
    used=set();files=0
    pattern=re.compile(r"(?<!\d)\d{8,10}(?!\d)")
    for name in result.stdout.splitlines():
        path=Path(name)
        if root in path.parents or path.stat().st_size>16_000_000:
            continue
        used.update(map(int,pattern.findall(path.read_text(errors="replace"))));files+=1
    return used,files

def plan(root,smoke):
    target=root/"plan.json"
    if target.exists():
        data=read(target);assert data["smoke"]==smoke
        return data
    excluded,files=previous_seeds(root)
    count=2 if smoke else 1000
    blocks=[]
    for i,seedroot in enumerate(ROOTS[:1] if smoke else ROOTS):
        rng=random.Random(seedroot)
        chosen=set()
        for h in HORIZONS:
            cases=[]
            while len(cases)<count:
                seed=rng.randrange(1_700_000_000+i*20_000_000,1_719_000_000+i*20_000_000)
                if seed not in excluded and seed not in chosen:
                    cases.append([h,seed]);chosen.add(seed)
            blocks.append(dict(root=seedroot,horizon=h,cases=cases))
    data=dict(schema=1,smoke=smoke,primary_comparison="latest-baseline",
              episode_count_per_horizon=count,seed_roots=list(ROOTS[:1] if smoke else ROOTS),
              excluded_request_files=files,excluded_numbers=len(excluded),blocks=blocks,
              expected_transitions=sum(h*len(block["cases"])*4 for block in blocks for h in [block["horizon"]]),
              policy_hashes={k:h for k,(_,h) in MODELS.items()},
              source_hash=digest(__file__),
              evaluator_hash=digest(REPO/"scripts/continuous_official_search.py"),
              backend_hash=digest(REPO/"scripts/continuous-official-search.lisp"),
              seed_policy="Disjoint new blocks; conservatively exclude recorded historical request seeds.",
              decision_policy="Research replication only; no automatic promotion or checkpoint replacement.")
    save(target,data)
    return data

def per_host(trajectory):
    result=defaultdict(float)
    for r in trajectory:
        for host,parts in json.loads(r["host"]).items():
            result[host]+=sum(parts)
    return dict(result)

def summarize_job(root,folder,seedroot):
    returns={(int(r["horizon"]),int(r["seed"]),r["arm"]):number(r["return"]) for r in rows(folder/"returns.tsv")}
    records=[]
    path=folder/"paired-episodes.jsonl"
    with path.open("w") as out:
        for key,group in groupby(rows(folder/"trace.tsv"),key=lambda r:(int(r["horizon"]),int(r["seed"]))):
            h,seed=key
            trajectories=defaultdict(list)
            for r in group:
                trajectories[r["arm"]].append(r)
            assert set(trajectories)==set(MODELS)
            host={k:per_host(v) for k,v in trajectories.items()}
            restores={k:sum(int(r["restore"]) for r in v) for k,v in trajectories.items()}
            for child,parent in COMPARISONS:
                a,b=trajectories[parent],trajectories[child]
                first=next((i for i,(x,y) in enumerate(zip(a,b)) if x["concrete"]!=y["concrete"]),None)
                if first is not None:
                    assert a[first]["obs"]==b[first]["obs"] and a[first]["mask"]==b[first]["mask"],"Divergence preceded by mismatched prefix state"
                delta=returns[h,seed,child]-returns[h,seed,parent]
                restore=restores[child]-restores[parent]
                host_delta={k:host[child].get(k,0)-host[parent].get(k,0) for k in host[parent].keys()|host[child].keys()}
                assert abs(sum(host_delta.values())-restore-delta)<1e-6
                entry=dict(root=seedroot,horizon=h,seed=seed,comparison=child+"-"+parent,
                    baseline=returns[h,seed,parent],candidate=returns[h,seed,child],delta=delta,
                    first_action_divergence=first,displaced=a[first]["pair"] if first is not None else None,
                    replacement=b[first]["pair"] if first is not None else None,
                    divergence_obs=a[first]["obs"] if first is not None else None,
                    divergence_mask=a[first]["mask"] if first is not None else None,
                    restore_delta=restore,host_reward_delta=host_delta)
                records.append(entry);out.write(json.dumps(entry,sort_keys=True)+"\n")
    return records

def describe(records):
    differences=[r["delta"] for r in records]
    b=sorted(r["baseline"] for r in records)
    c=sorted(r["candidate"] for r in records)
    tail=max(1,math.ceil(len(b)*0.1))
    return dict(stats(differences),changed_episodes=sum(r["first_action_divergence"] is not None for r in records),
        baseline_mean=statistics.mean(b),candidate_mean=statistics.mean(c),
        baseline_min=min(b),candidate_min=min(c),
        cvar10_delta=statistics.mean(c[:tail])-statistics.mean(b[:tail]),
        new_catastrophes=sum(r["candidate"] < -100 <= r["baseline"] for r in records),
        rescued_catastrophes=sum(r["baseline"] < -100 <= r["candidate"] for r in records),
        restore_delta=statistics.mean(r["restore_delta"] for r in records),
        host_reward_delta={host:statistics.mean(r["host_reward_delta"].get(host,0) for r in records)
                           for host in set().union(*(r["host_reward_delta"] for r in records))},
        displaced= dict(Counter((r["displaced"]+" -> "+r["replacement"]) for r in records if r["displaced"] is not None)))

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--output",required=True);p.add_argument("--workers",type=int,default=6)
    p.add_argument("--smoke",action="store_true");args=p.parse_args()
    root=Path(args.output).resolve();root.mkdir(parents=True,exist_ok=True)
    models=frozen(root);protocol=plan(root,args.smoke)
    assert protocol["source_hash"]==digest(__file__)
    for name,expected in (("evaluator_hash","scripts/continuous_official_search.py"),("backend_hash","scripts/continuous-official-search.lisp")):
        assert protocol[name]==digest(REPO/expected)
    genotype=genotype_audit(root,models)
    jobs=[]
    for block in protocol["blocks"]:
        for start in range(0,len(block["cases"]),100):
            folder=root/f"root-{block['root']}"/f"h{block['horizon']}-part-{start//100:02}"
            jobs.append((block["root"],folder,block["cases"][start:start+100]))
    log(root,"START",jobs=len(jobs),workers=args.workers,nominal_transitions=protocol["expected_transitions"])
    completed=0;all_records=[];spent=0
    def work(job):
        seedroot,folder,cases=job
        if folder.exists() and not (folder/"complete.json").exists() and (folder/"trace.tsv").exists():
            raise RuntimeError(f"Interrupted evidence preserved; inspect before retry: {folder}")
        result=evaluate_job("b_line",folder,cases,models)
        return seedroot,result,summarize_job(root,result,seedroot)
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures={pool.submit(work,job):job for job in jobs}
        for future in as_completed(futures):
            seedroot,folder,records=future.result()
            all_records.extend(records);completed+=1
            spent+=read(folder/"complete.json")["transitions"]
            save(root/"progress.json",dict(completed_jobs=completed,total_jobs=len(jobs),transitions=spent))
            log(root,"PROGRESS",completed=f"{completed}/{len(jobs)}",transitions=spent,folder=str(folder.relative_to(root)))
    results={}
    for scope in (*protocol["seed_roots"],"combined"):
        groups=defaultdict(lambda:defaultdict(list))
        for r in all_records:
            if scope=="combined" or r["root"]==scope:
                groups[r["comparison"]][str(r["horizon"])].append(r)
        cells={comparison:{h:describe(values) for h,values in by_h.items()} for comparison,by_h in groups.items()}
        results[str(scope)]={}
        for comparison,values in cells.items():
            mean=sum(c["mean"] for c in values.values())
            se=math.sqrt(sum(c["se"]**2 for c in values.values()))
            results[str(scope)][comparison]=dict(horizons=values,total_delta=mean,total_se=se,
                total_lower95=mean-1.96*se,total_upper95=mean+1.96*se,
                baseline_total=sum(c["baseline_mean"] for c in values.values()),
                candidate_total=sum(c["candidate_mean"] for c in values.values()))
    assert spent==protocol["expected_transitions"]
    save(root/"results.json",dict(comparisons=results,transitions=spent,genotype_audit=genotype,
                                 primary="latest-baseline",promotion_performed=False))
    (root/"DONE").write_text("done\n")
    log(root,"DONE",transitions=spent,results=str(root/"results.json"))

if __name__=="__main__":
    main()


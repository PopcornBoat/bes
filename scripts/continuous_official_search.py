"""Continuous teacher-free official search; all policy changes remain native 62D TPGs.

This entry point owns a bounded incubation population. It does not replace the
legacy main.lisp population or its grouped selection. Only strict full-validation
winners advance this search's incumbent; existing validated files are immutable.
"""
from __future__ import annotations
import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
import csv
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import random
import shutil
import statistics
import subprocess
import time

REPO = Path(__file__).resolve().parents[1]
BACKEND = REPO / "scripts/continuous-official-search.lisp"
VENV = Path.home() / "venv-base/cage2_bridge/.venv"
TARGETS = (1, 2, 3, 4, 5, 7, 8, 9, 10)
STARTS = {1:0, 2:4, 3:8, 4:12, 5:28, 7:36, 8:40, 9:44, 10:48}
SCAN = {1:52, 2:53, 3:54, 4:55, 5:56, 7:58, 8:59, 9:60, 10:61}
# Scan index mapping is exported/verified against Controller by tests before use.
OFFSETS = {1:0, 2:1, 3:2, 4:3, 5:7, 7:9, 8:10, 9:11, 10:12}
LANES = ("rare", "persistent", "repeat", "random")
STREAMS = ("discovery", "screen", "confirm", "promotion", "mutation", "nomination")
BASE = 1_000_000_000
WIDTH = 15_000_000

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w") as f:
        json.dump(value, f, indent=2, sort_keys=True, allow_nan=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(temporary, path)

def read(path):
    return json.loads(Path(path).read_text())

def number(value):
    return float(value.replace("d", "e").replace("D", "e"))

def rows(path):
    with Path(path).open() as f:
        reader = csv.DictReader(f, delimiter="\t")
        reader.fieldnames = [x.lower() for x in reader.fieldnames]
        yield from reader

def sexp(value):
    if value is None:
        return "nil"
    if isinstance(value, (list, tuple)):
        return "(" + " ".join(map(sexp, value)) + ")"
    return json.dumps(value) if isinstance(value, str) else str(value)

def write_sexp(path, value):
    Path(path).write_text(sexp(value) + "\n")

def run_lisp(form, folder):
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, PYTHONHASHSEED="0", OPENBLAS_NUM_THREADS="1",
               OMP_NUM_THREADS="1", MKL_NUM_THREADS="1", CUDA_VISIBLE_DEVICES="-1",
               CL_SOURCE_REGISTRY=f'(:source-registry (:directory "{REPO}/") :ignore-inherited-configuration)')
    env["PATH"] = str(VENV / "bin") + os.pathsep + env["PATH"]
    command = ["sbcl", "--dynamic-space-size", "1536", "--noinform", "--non-interactive",
               "--eval", "(require :asdf)", "--eval", "(asdf:load-system :cl-tpg)",
               "--load", str(BACKEND), "--eval", form]
    with (folder / "worker.log").open("w") as f:
        process = subprocess.run(command, cwd=REPO, env=env, stdout=f, stderr=subprocess.STDOUT)
    if process.returncode:
        raise RuntimeError(f"SBCL failed: {folder / 'worker.log'}")

def call(name, *args):
    return "(cl-tpg::continuous-" + name + " " + " ".join(sexp(x) for x in args) + ")"

def schedule(opponent, folder):
    path = folder / "schedule.tsv"
    if not path.exists():
        run_lisp(call("contract", opponent, str(path)), folder / "contract")
    return [(int(r["target"]), int(r["option"]), int(r["concrete"]), int(r["mask"]))
            for r in rows(path)]

def ranking(text):
    return [tuple(map(int, item.split(":"))) for item in text.split(";") if item]

def resolve(ranks, mask, orders):
    """Exact current :PROFILE global Controller, with Restore Top-1 only."""
    considered = False
    for i, (target, response) in enumerate(ranks[:8]):
        if target == 0:
            return (0, 0), 1
        if response == 2 and i:
            continue
        if response == 3:
            if not considered:
                considered = True
                decoys = {t for t, r in ranks[:8] if r == 3}
                for t, _, concrete, bit in orders:
                    if t in decoys and not (mask & bit):
                        return (t, 3), concrete
            continue
        base = (2, 15, 132)[response]
        return (target, response), base + OFFSETS[target]
    return (0, 0), 1

def stats(values):
    n = len(values)
    mean = statistics.mean(values)
    se = statistics.stdev(values) / math.sqrt(n) if n > 1 else 0.0
    return dict(n=n, mean=mean, se=se, lower=mean-1.96*se, upper=mean+1.96*se,
                wins=sum(x > 1e-8 for x in values), losses=sum(x < -1e-8 for x in values),
                ties=sum(abs(x) <= 1e-8 for x in values))

def permissive(c):
    # Negative filtering only. Zero/uncertain outcomes retain an exploration chance.
    return not c["new_catastrophes"] and c["upper"] >= -0.25

def promotion(result):
    total_mean = sum(c["mean"] for c in result.values())
    total_se = math.sqrt(sum(c["se"]**2 for c in result.values()))
    # Preserve the existing >1 SE mean criterion; add fresh full/tail safeguards.
    return (total_mean > total_se + 1e-8
            and all(c["mean"]+c["se"] >= -1e-8 for c in result.values())
            and all(not c["new_catastrophes"] and c["cvar_delta"] >= -0.25 for c in result.values()))

def evaluate_job(opponent, folder, cases, arms):
    folder.mkdir(parents=True, exist_ok=True)
    manifest = dict(cases=cases, arms={name:dict(path=str(p), sha=digest(p)) for name,p in arms.items()})
    request = folder / "request.json"
    if request.exists():
        assert read(request) == json.loads(json.dumps(manifest))
    else:
        save(request, manifest)
    complete = folder / "complete.json"
    if complete.exists():
        assert read(complete)["request_sha"] == digest(request)
        return folder
    # Incomplete worker output is never mistaken for a completed evidence set.
    for filename in ("trace.tsv", "returns.tsv"):
        (folder / filename).unlink(missing_ok=True)
    write_sexp(folder / "arms.sexp", [(n,str(p)) for n,p in arms.items()])
    write_sexp(folder / "cases.sexp", cases)
    run_lisp(call("evaluate", opponent, str(folder/"arms.sexp"), str(folder/"cases.sexp"), str(folder)+"/"), folder)
    totals = {(int(r["horizon"]),int(r["seed"]),r["arm"]):number(r["return"]) for r in rows(folder/"returns.tsv")}
    expected = {(h, seed, name) for h, seed in cases for name in arms}
    assert set(totals) == expected
    counts, sums = Counter(), defaultdict(float)
    for r in rows(folder/"trace.tsv"):
        key = int(r["horizon"]),int(r["seed"]),r["arm"]
        assert int(r["step"]) == counts[key] and len(r["obs"]) == 62
        counts[key] += 1
        sums[key] += number(r["reward"])
    assert all(counts[k] == k[0] and abs(sums[k]-totals[k]) < 1e-7 for k in expected)
    save(complete, dict(request_sha=digest(request), transitions=sum(counts.values())))
    return folder

def stage_report(folders, models):
    totals, traces = {}, defaultdict(list)
    for folder in folders:
        for r in rows(folder/"returns.tsv"):
            key = int(r["horizon"]),int(r["seed"]),r["arm"]
            assert key not in totals
            totals[key] = number(r["return"])
        for r in rows(folder/"trace.tsv"):
            traces[int(r["horizon"]),int(r["seed"]),r["arm"]].append(r)
    result = {}
    for name in models:
        cells = {}
        for h in sorted({k[0] for k in totals}):
            seeds = sorted(k[1] for k in totals if k[0] == h and k[2] == name)
            if not seeds:
                continue
            differences, changed, events = [],0,[]
            baseline, candidate, net_restore, host_delta = [],[],0,0.0
            for seed in seeds:
                b, c = totals[h,seed,"baseline"],totals[h,seed,name]
                baseline.append(b); candidate.append(c); differences.append(c-b)
                bt,ct = traces[h,seed,"baseline"],traces[h,seed,name]
                first = next((i for i,(x,y) in enumerate(zip(bt,ct)) if x["concrete"] != y["concrete"]),None)
                if first is not None:
                    changed += 1
                    events.append(dict(seed=seed,step=first,incumbent=bt[first]["pair"],offspring=ct[first]["pair"]))
                restores = sum(int(x["restore"]) for x in ct)-sum(int(x["restore"]) for x in bt)
                losses_b = sum(sum(sum(v) for v in json.loads(x["host"]).values()) for x in bt)
                losses_c = sum(sum(sum(v) for v in json.loads(x["host"]).values()) for x in ct)
                assert abs((losses_c-losses_b)-restores-(c-b)) < 1e-6
                net_restore += restores
                host_delta += losses_c-losses_b
            tail = max(1,math.ceil(len(seeds)*0.1))
            cells[str(h)] = dict(stats(differences), changed_episodes=changed, first_divergences=events,
                                  baseline_mean=statistics.mean(baseline), offspring_mean=statistics.mean(candidate),
                                  restore_delta=net_restore/len(seeds), host_reward_delta=host_delta/len(seeds),
                                  new_catastrophes=sum(c < -100 <= b for b,c in zip(baseline,candidate)),
                                  cvar_delta=statistics.mean(sorted(candidate)[:tail])-statistics.mean(sorted(baseline)[:tail]))
        result[name] = cells
    return result

class Search:
    def __init__(self, args):
        self.args=args
        self.root=Path(args.output).resolve()
        self.root.mkdir(parents=True,exist_ok=True)
        self.lock=(self.root/"search.lock").open("a")
        fcntl.flock(self.lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        self.path=self.root/"state.json"
        if self.path.exists():
            self.state=read(self.path)
            assert self.state["opponent"] == args.opponent and self.state["root_seed"] == args.seed
            assert self.state["backend_sha"] == digest(BACKEND)
            assert self.state["source_sha"] == digest(__file__)
            # Population is serialized checkpoints; reconstruction is intentional.
            for item in [self.state["incumbent"],*self.state["lineages"]]:
                assert digest(item["path"]) == item["sha"]
        else:
            source=Path(args.checkpoint).resolve()
            target=self.root/"initial.lisp"
            shutil.copyfile(source,target);target.chmod(0o444)
            self.state=dict(schema=1,opponent=args.opponent,root_seed=args.seed,cycle=0,
                            incumbent=dict(path=str(target),sha=digest(target)),lineages=[],
                            streams={s:0 for s in STREAMS},budget_reserved=0,budget_completed=0,
                            jobs={},opportunities_tested=[],backend_sha=digest(BACKEND),source_sha=digest(__file__))
            self.flush()
        self.orders=schedule(args.opponent,self.root)
        protocol={k:v for k,v in vars(args).items() if k not in ("output","checkpoint","cycles","transitions","workers")}
        protocol_file=self.root/"protocol.json"
        if protocol_file.exists():
            assert read(protocol_file)==protocol, "Resume must preserve the search protocol"
        else:
            save(protocol_file,protocol)
        self.log("START",incumbent=self.state["incumbent"]["sha"][:12],cycles=self.state["cycle"])

    def flush(self):
        save(self.path,self.state)

    def log(self,event,**fields):
        record=dict(time=time.strftime("%Y-%m-%d %H:%M:%S"),event=event,**fields)
        with (self.root/"events.jsonl").open("a") as f:
            f.write(json.dumps(record,sort_keys=True)+"\n")
        print(record["time"],event," ".join(f"{k}={v}" for k,v in fields.items()),flush=True)

    def seeds(self,stream,n):
        cursor=self.state["streams"][stream]
        index=STREAMS.index(stream)+(6 if self.args.opponent=="meander" else 0)
        block=BASE+index*WIDTH
        assert cursor+n < WIDTH
        # A seeded affine permutation within a prime-sized domain avoids repeats
        # while rotating episode seeds. Different streams occupy disjoint ranges.
        prime=14_999_993
        assert cursor+n<=prime, "Seed-stream domain exhausted"
        salt=int(hashlib.sha256(f"{self.args.seed}:{stream}".encode()).hexdigest()[:12],16)%prime
        values=[block+(104729*(cursor+i)+salt)%prime for i in range(n)]
        self.state["streams"][stream]+=n
        return values

    def stage(self,cycle,name,cases,parent,models):
        path=cycle/name
        path.mkdir(parents=True,exist_ok=True)
        plan=path/"plan.json"
        if not plan.exists():
            cost=sum(h for h,_ in cases)*(1+len(models))
            if self.state["budget_reserved"]+cost > self.args.transitions:
                raise BudgetExceeded
            save(plan,dict(cases=cases,parent=parent,models=models,cost=cost))
            self.state["jobs"][str(path)]=dict(reserved=cost,complete=False)
            self.state["budget_reserved"]+=cost
            self.flush()
        else:
            p=read(plan)
            cases=p["cases"];parent=p["parent"];models=p["models"]
            if str(path) not in self.state["jobs"]:
                # Transaction recovery if interrupted between plan and state.
                self.state["jobs"][str(path)]=dict(reserved=p["cost"],complete=False)
                self.state["budget_reserved"]+=p["cost"]
                self.flush()
        group=[{"baseline":Path(parent)}]
        items=list(models.items())
        group += [dict((n,Path(p)) for n,p in items[i:i+3]) for i in range(0,len(items),3)]
        # Reserve failed/interrupted attempts conservatively before any retry.
        for i,arms in enumerate(group):
            worker=path/f"worker-{i:03}"
            if (worker/"worker.log").exists() and not (worker/"complete.json").exists():
                extra=sum(h for h,_ in cases)*len(arms)
                if self.state["budget_reserved"]+extra>self.args.transitions:
                    raise BudgetExceeded
                self.state["budget_reserved"]+=extra
                retry=worker/f"interrupted-{time.time_ns()}"
                retry.mkdir()
                for filename in ("worker.log","trace.tsv","returns.tsv"):
                    if (worker/filename).exists():
                        (worker/filename).rename(retry/filename)
                self.log("RETRY_RESERVED",stage=name,transitions=extra,archive=str(retry))
                self.flush()
        def work(item):
            i,arms=item
            return evaluate_job(self.args.opponent,path/f"worker-{i:03}",cases,arms)
        self.log("EVALUATE",cycle=self.state["cycle"],stage=name,candidates=len(models),episodes=len(cases),transitions=read(plan)["cost"])
        with ThreadPoolExecutor(max_workers=self.args.workers) as pool:
            folders=list(pool.map(work,enumerate(group)))
        report=stage_report(folders,models)
        save(path/"results.json",report)
        job=self.state["jobs"][str(path)]
        if not job["complete"]:
            job["complete"]=True
            self.state["budget_completed"]+=job["reserved"]
            self.flush()
        self.log("EVALUATED",stage=name,completed_transitions=self.state["budget_completed"])
        return report,folders

    def stage_cases(self,cycle,name,stream,n,horizons=(100,)):
        path=cycle/(name+"-seeds.json")
        if path.exists():
            return read(path)
        cases=[[h,seed] for h in horizons for seed in self.seeds(stream,n)]
        # Persist stream allocation first; a crash may skip unused seeds, never reuse them.
        self.flush()
        save(path,cases)
        return cases

    def catalogue(self,traces):
        groups=defaultdict(list)
        execution=Counter()
        for row in traces:
            if int(row["step"]) < 3:
                continue
            obs=row["obs"]; ranks=ranking(row["top8"]); mask=int(row["mask"])
            pair,concrete=resolve(ranks,mask,self.orders)
            assert pair == tuple(map(int,row["pair"].split(":"))) and concrete==int(row["concrete"])
            execution[pair]+=1
            for target in TARGETS:
                code=obs[STARTS[target]:STARTS[target]+4]
                scan=obs[SCAN[target]] if SCAN[target] is not None else "-"
                # Target-symmetric groups, no privileged state or fixed host labels.
                group=(target,code,scan)
                groups[group].append(row)
        candidates=[]
        for (target,code,scan),contexts in groups.items():
            seeds={int(r["seed"]) for r in contexts}
            if len(seeds)<2:
                continue
            for response in range(4):
                alt=(target,response)
                relevant=[]
                for r in contexts:
                    native=ranking(r["top8"])
                    desired=[alt]+[a for a in native if a!=alt][:7]
                    pair,concrete=resolve(desired,int(r["mask"]),self.orders)
                    if pair!=alt or concrete==int(r["concrete"]):
                        continue
                    relevant.append(r)
                if not relevant:
                    continue
                unique=defaultdict(set)
                for r in relevant:
                    unique[r["obs"]].add(int(r["seed"]))
                observations=sorted(unique,key=lambda x:(-len(unique[x]),x))[:8]
                signature=hashlib.sha256(sexp([observations,alt]).encode()).hexdigest()[:12]
                seeds={int(r["seed"]) for r in relevant if r["obs"] in observations}
                if len(seeds)<2:
                    continue
                dominated=Counter(r["pair"] for r in relevant)
                candidates.append(dict(key=signature,target=target,code=code,scan=scan,alt=alt,
                    observations=observations,exposure=len(seeds),rows=len(relevant),
                    rare=1/(1+execution[alt]),persistent=len(contexts)/len({int(r["seed"]) for r in contexts}),
                    repeat=dominated.most_common(1)[0][1]/len(relevant),
                    displaced=dict(dominated),current_top8_support=sum(alt in ranking(r["top8"]) for r in relevant)/len(relevant)))
        return candidates

    def generate(self,cycle,discovery,parent):
        manifest=cycle/"candidates.json"
        if manifest.exists():
            return read(manifest)
        traces=[r for f in discovery for r in rows(f/"trace.tsv") if r["arm"]=="baseline"]
        catalogue=self.catalogue(traces)
        used=set(self.state.get("opportunities_tested",[]))
        catalogue=[c for c in catalogue if digest(parent)+":"+c["key"] not in used]
        save(cycle/"catalogue.json",catalogue)
        generation_plan=cycle/"generation-plan.json"
        if generation_plan.exists():
            rng=random.Random(0)  # Frozen selected entries below replace this temporary ordering.
        else:
            rng=random.Random(self.seeds("nomination",1)[0])
            self.flush()
        per_lane=max(1,self.args.candidates//8)
        selected=[];seen=set();group_counts=Counter()
        for lane in LANES:
            items=list(catalogue)
            if lane=="random":
                rng.shuffle(items)
            else:
                items.sort(key=lambda c:(-c[lane],-c["exposure"],c["key"]))
            taken=0
            for c in items:
                # Same state group cannot consume a whole batch.
                group=(c["target"],c["code"],c["scan"])
                if c["key"] in seen or group_counts[group]>=2:
                    continue
                selected.append(dict(c,source_lane=lane,kind="specialist"))
                seen.add(c["key"]);group_counts[group]+=1;taken+=1
                if taken>=per_lane:
                    break
        rng.shuffle(catalogue)
        for c in catalogue:
            if len(selected)>=self.args.candidates//2:
                break
            group=(c["target"],c["code"],c["scan"])
            if c["key"] not in seen and group_counts[group]<2:
                selected.append(dict(c,source_lane="random-fill",kind="specialist"))
                seen.add(c["key"]);group_counts[group]+=1
        probes=sorted({(r["obs"],int(r["mask"])) for r in traces if int(r["step"])>=3})
        rng.shuffle(probes);target_obs={o for c in selected for o in c["observations"]}
        targeted=[p for p in probes if p[0] in target_obs]
        background=[p for p in probes if p[0] not in target_obs][:64]
        probes=targeted[:256]+background
        if not probes:
            raise RuntimeError("No post-opening observations")
        save(cycle/"probe-contexts.json",probes)
        # Native instruction, atomic-terminal, learner and graph variations remain.
        parents=[self.state["incumbent"],*self.state["lineages"][:self.args.lineages]]
        modes=("active-instruction","terminal","team","instruction")
        while len(selected)<self.args.candidates:
            i=len(selected)
            selected.append(dict(key=f"native-{i}",kind=modes[i%len(modes)],
                                 source_lane="native",observations=[probes[i%len(probes)][0]],alt=None,
                                 parent=parents[(i-self.args.candidates//2)%len(parents)]))
        output=cycle/"offspring";output.mkdir(exist_ok=True)
        generation_plan=cycle/"generation-plan.json"
        if generation_plan.exists():
            fixed=read(generation_plan)
            selected=fixed["selected"];probes=fixed["probes"];mutation_seeds=fixed["seeds"]
        else:
            mutation_seeds=self.seeds("mutation",len(selected));self.flush()
            save(generation_plan,dict(selected=selected,probes=probes,seeds=mutation_seeds))
        # Baseline concrete decisions and off-target probes use the same Controller.
        probe_lookup={(r["obs"],int(r["mask"])):r for r in traces}
        baseline_actions=[probe_lookup[tuple(p)]["concrete"] for p in probes]
        built={};unchanged=0
        for i,(spec,seed) in enumerate(zip(selected,mutation_seeds)):
            name=f"c{self.state['cycle']:04}-{i:02}-{spec['key']}"
            source=spec.get("parent",parents[i%len(parents)])
            # A directed child may inherit a neutral parent's earlier refinement.
            # Its nomination remains a hypothesis; full policy evaluation is vs incumbent.
            folder=output/name;folder.mkdir(exist_ok=True)
            existing=folder/"candidate.json"
            if existing.exists():
                item=read(existing)
                assert digest(item["path"])==item["sha"]
                built[name]=item
                continue
            checkpoint=folder/(name+".lisp")
            if checkpoint.exists():
                checkpoint.chmod(0o644)
            write_sexp(folder/"request.sexp",[[name,spec["kind"],seed,spec["observations"],spec.get("alt")]])
            try:
                run_lisp(call("build",self.args.opponent,source["path"],str(folder/"request.sexp"),str(folder)+"/"),folder/"build")
                checkpoint=folder/(name+".lisp")
                write_sexp(folder/"probes.sexp",probes)
                (folder/"probes.tsv").unlink(missing_ok=True)
                run_lisp(call("probe",self.args.opponent,str(checkpoint),str(folder/"probes.sexp"),str(folder/"probes.tsv")),folder/"probe")
                actual=list(rows(folder/"probes.tsv"))
                actions=[r["concrete"] for r in actual]
                changed=sum(a!=b for a,b in zip(actions,baseline_actions))
                if not changed:
                    unchanged+=1
                    self.log("INACTIVE",candidate=name)
                    continue
                signature=hashlib.sha256(json.dumps(actions).encode()).hexdigest()
                if signature in {b["behavior_signature"] for b in built.values()}:
                    self.log("DUPLICATE",candidate=name)
                    continue
                checkpoint.chmod(0o444)
                built[name]=dict(spec,path=str(checkpoint),sha=digest(checkpoint),parent_sha=source["sha"],
                                 mutation_seed=seed,behavior_signature=signature,
                                 probes=len(actual),changed_probe_contexts=changed,generation=self.state["cycle"])
                save(existing,built[name])
            except (RuntimeError,AssertionError) as error:
                self.log("INVALID",candidate=name,error=str(error))
        save(manifest,built)
        self.state["opportunities_tested"]=sorted(used|{digest(parent)+":"+c["key"] for c in selected if c["kind"]=="specialist"})
        self.flush()
        # A generation with no active offspring still collects new experience next round.
        self.log("GENERATED",catalogue=len(catalogue),valid=len(built),inactive=unchanged,lanes=dict(Counter(c["source_lane"] for c in built.values())))
        return built

    def cycle(self):
        n=self.state["cycle"]
        cycle=self.root/f"cycle-{n:04}";cycle.mkdir(exist_ok=True)
        frozen=cycle/"incumbent.json"
        if not frozen.exists():
            save(frozen,self.state["incumbent"])
        parent=read(frozen)["path"]
        discovery_cases=self.stage_cases(cycle,"discovery","discovery",self.args.discovery)
        _,data=self.stage(cycle,"discovery",discovery_cases,parent,{})
        built=self.generate(cycle,data,parent)
        models={name:c["path"] for name,c in built.items()}
        if not models:
            save(cycle/"summary.json",dict(cycle=n,valid_offspring=0,promoted=None))
            self.state["cycle"]+=1;self.flush()
            self.log("CYCLE_DONE",cycle=n,valid_offspring=0)
            return
        cases=self.stage_cases(cycle,"screen","screen",self.args.screen)
        initial,_=self.stage(cycle,"screen",cases,parent,models)
        eligible=[name for name in models if permissive(initial[name]["100"]) and initial[name]["100"]["changed_episodes"]]
        # Allocate by lane round-robin, not just the luckiest noisy maximum.
        buckets=defaultdict(list)
        for name in eligible:
            buckets[built[name]["source_lane"]].append(name)
        for values in buckets.values():
            values.sort(key=lambda k:(-initial[k]["100"]["mean"],k))
        finalists=[]
        while len(finalists)<self.args.finalists and any(buckets.values()):
            for lane in sorted(buckets):
                if buckets[lane] and len(finalists)<self.args.finalists:
                    finalists.append(buckets[lane].pop(0))
        confirmed={}
        if finalists:
            cases=self.stage_cases(cycle,"racing","screen",self.args.racing)
            intermediate,_=self.stage(cycle,"racing",cases,parent,{k:models[k] for k in finalists})
            finalists=[k for k in finalists if permissive(intermediate[k]["100"])]
        if finalists:
            cases=self.stage_cases(cycle,"confirmation","confirm",self.args.confirm)
            confirmed,_=self.stage(cycle,"confirmation",cases,parent,{k:models[k] for k in finalists})
        hopeful=[k for k in confirmed if confirmed[k]["100"]["mean"]>1e-8
                 and not confirmed[k]["100"]["new_catastrophes"]]
        promoted=None
        full={}
        if hopeful and not self.args.no_promotion:
            hopeful.sort(key=lambda k:(-confirmed[k]["100"]["lower"],k))
            winner=hopeful[0]
            cases=self.stage_cases(cycle,"promotion","promotion",self.args.full,(30,50,100))
            full,_=self.stage(cycle,"promotion",cases,parent,{winner:models[winner]})
            if promotion(full[winner]):
                promoted=winner
                self.state["incumbent"]=dict(path=models[winner],sha=built[winner]["sha"])
                self.log("PROMOTED",candidate=winner,total_delta=sum(c["mean"] for c in full[winner].values()))
        pool=[]
        for name in eligible:
            c=confirmed.get(name,initial[name])["100"]
            if permissive(c) and name!=promoted:
                pool.append(dict(path=models[name],sha=built[name]["sha"],mean=c["mean"],se=c["se"],
                                 behavior_signature=built[name]["behavior_signature"],generation=n,source_lane=built[name]["source_lane"]))
        # Bounded neutral population, periodically refreshed, distinct behavior.
        pool+=self.state["lineages"]
        selected=[];signatures=set()
        for item in sorted(pool,key=lambda c:(-c["generation"],-c["mean"])):
            if item["behavior_signature"] not in signatures and item["sha"]!=self.state["incumbent"]["sha"]:
                selected.append(item);signatures.add(item["behavior_signature"])
            if len(selected)==self.args.lineages:
                break
        self.state["lineages"]=selected
        summary=dict(cycle=n,nominated=len(read(cycle/"catalogue.json")),valid_offspring=len(built),
                     activated=sum(initial[k]["100"]["changed_episodes"]>0 for k in models),
                     negative_filtered=len(models)-len(eligible),confirmed=len(confirmed),positive_mean_confirmation=len(hopeful),
                     promoted=promoted,lineages=selected,budget_completed=self.state["budget_completed"])
        save(cycle/"summary.json",summary)
        self.state["cycle"]+=1;self.flush()
        self.log("CYCLE_DONE",**{k:v for k,v in summary.items() if k!="lineages"})

    def run(self):
        try:
            while self.state["cycle"]<self.args.cycles and not (self.root/"STOP").exists():
                self.cycle()
        except BudgetExceeded:
            self.log("BUDGET_STOP",reserved=self.state["budget_reserved"],limit=self.args.transitions)
        self.log("DONE",cycles=self.state["cycle"],incumbent=self.state["incumbent"]["sha"],transitions=self.state["budget_completed"])

class BudgetExceeded(Exception):
    pass

def parser():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--opponent",choices=("b_line","meander"),required=True)
    p.add_argument("--checkpoint",required=True)
    p.add_argument("--output",required=True)
    p.add_argument("--seed",type=int,default=202611181920)
    p.add_argument("--workers",type=int,default=3)
    p.add_argument("--cycles",type=int,default=24)
    p.add_argument("--transitions",type=int,default=2_000_000)
    p.add_argument("--candidates",type=int,default=16)
    p.add_argument("--discovery",type=int,default=24)
    p.add_argument("--screen",type=int,default=12)
    p.add_argument("--racing",type=int,default=40)
    p.add_argument("--confirm",type=int,default=100)
    p.add_argument("--finalists",type=int,default=4)
    p.add_argument("--lineages",type=int,default=4)
    p.add_argument("--full",type=int,default=1000)
    p.add_argument("--no-promotion",action="store_true",help="Diagnostic smoke mode; never update incumbent")
    return p

if __name__=="__main__":
    args=parser().parse_args()
    if args.full!=1000:
        raise ValueError("Official full-validation size is fixed at 1000 per horizon")
    Search(args).run()


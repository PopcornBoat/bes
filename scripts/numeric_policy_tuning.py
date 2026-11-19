"""Fixed-genotype numeric random search and Gaussian ES direction diagnostic.

The same immutable mother and coordinate directions are used in full-vector
and data-derived active-vector studies. Only existing eligible literal numbers
change. No learner, instruction, edge, terminal, EQ category or ROR is altered.
"""
import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
import csv
import fcntl
import json
import math
from pathlib import Path
import random
import re
import shutil
import time
from continuous_official_search import (
    REPO, digest, read, save, rows, number, run_lisp, evaluate_job, stage_report, stats)
from replicate_search_lineage import previous_seeds
from numeric_policy_math import antithetic_gradient, step_for_gradient, matched_random_step, physical_patch, norm

SOURCE=Path.home()/"bes-artifacts/runtime/continuous-official-search-20261118/b_line/initial.lisp"
SOURCE_HASH="cda3f1d75bdec6a6622974af492d4396753f427619d41afcd93d3509a9e12994"
NATIVE=REPO/"scripts/numeric-policy-parameters.lisp"
SIGMAS=(0.05,0.5)
STAGE_COUNTS={"discovery":16,"probe":4,"validation":40,"confirmation":100}

def sx(value):
    if isinstance(value,float):
        if not math.isfinite(value):raise ValueError("Nonfinite numeric parameter")
        text=format(value,".17g")
        return text.replace("e","d") if "e" in text else text+"d0"
    if isinstance(value,(tuple,list)):return "("+" ".join(sx(x) for x in value)+")"
    return json.dumps(value) if isinstance(value,str) else str(value)

def log(root,event,**values):
    print(time.strftime("%Y-%m-%d %H:%M:%S"),event," ".join(f"{k}={v}" for k,v in values.items()),flush=True)
    with (root/"events.jsonl").open("a") as f:
        f.write(json.dumps(dict(event=event,time=time.time(),**values),sort_keys=True)+"\n")

def native_call(function,*values):
    return "(progn (load "+sx(str(NATIVE))+") (cl-tpg::numeric-"+function+" "+" ".join(sx(v) for v in values)+"))"

def build_models(root,mother,specifications):
    folder=root/"models";folder.mkdir(exist_ok=True)
    if not specifications:return {}
    request=folder/"build.sexp"
    if not (folder/"complete.json").exists():
        groups=[list(specifications)[i:i+8] for i in range(0,len(specifications),8)]
        def build(group):
            index,names=group
            part=folder/f"build-{index:03}.sexp"
            part.write_text(sx([(name,specifications[name]["patch"]) for name in names])+"\n")
            run_lisp(native_call("policy-build","b_line",str(mother),str(part),str(folder)+"/"),folder/f"builder-{index:03}")
            return len(names)
        log(root,"BUILD",candidates=len(specifications))
        with ThreadPoolExecutor(max_workers=3) as pool:
            futures=[pool.submit(build,group) for group in enumerate(groups)]
            for completed in as_completed(futures):
                log(root,"BUILT",batch_candidates=completed.result())
        for name in specifications:
            (folder/(name+".lisp")).chmod(0o444)
        save(folder/"complete.json",{name:digest(folder/(name+".lisp")) for name in specifications})
    models={}
    expected=read(folder/"complete.json")
    for name in specifications:
        p=folder/(name+".lisp")
        assert digest(p)==expected[name]
        models[name]=str(p)
    save(folder/"proposals.json",specifications)
    return models

def initialize(root):
    assert digest(SOURCE)==SOURCE_HASH
    mother=root/"mother.lisp"
    if not mother.exists():
        shutil.copyfile(SOURCE,mother);mother.chmod(0o444)
    assert digest(mother)==SOURCE_HASH
    inventory=root/"inventory";inventory.mkdir(exist_ok=True)
    if not (inventory/"parameters.tsv").exists():
        run_lisp(native_call("policy-export","b_line",str(mother),str(inventory)+"/"),inventory/"exporter")
    parameters={}
    for r in rows(inventory/"parameters.tsv"):
        parameters[int(r["id"])]=dict(
            id=int(r["id"]),node=int(r["node"]),learner=int(r["learner"]),
            instruction=int(r["instruction"]),operand=int(r["operand"]),
            value=number(r["value"]),unit=number(r["unit"]),eligible=int(r["eligible"]),kind=r["kind"])
    return mother,parameters

def plan(root,args,parameters):
    path=root/"plan.json"
    if path.exists():
        value=read(path)
        assert value["smoke"]==args.smoke and value["scope"]==args.scope
        assert value["source_hash"]==digest(__file__) and value["native_hash"]==digest(NATIVE)
        return value
    counts={k:(2 if args.smoke else v) for k,v in STAGE_COUNTS.items()}
    eligible=sorted(k for k,p in parameters.items() if p["eligible"])
    # New disjoint stage domains; scopes use identical episodes for comparability.
    shared=root.parent/("smoke-seeds.json" if args.smoke else "numeric-seeds.json")
    lock_file=(root.parent/(shared.name+".lock")).open("a")
    with lock_file:
        fcntl.flock(lock_file,fcntl.LOCK_EX)
        if shared.exists():
            seeds=read(shared)["seeds"]
        else:
            excluded,files=previous_seeds(root.parent)
            seeds={};chosen=set()
            for i,(stage,n) in enumerate(counts.items()):
                low=1_800_000_000+i*10_000_000+(50_000_000 if args.smoke else 0)
                rng=random.Random(202611190120+i)
                seeds[stage]=[]
                while len(seeds[stage])<n:
                    seed=rng.randrange(low,low+9_000_000)
                    if seed not in excluded and seed not in chosen:
                        seeds[stage].append(seed);chosen.add(seed)
            save(shared,dict(seeds=seeds,excluded_request_files=files,smoke=args.smoke))
    value=dict(schema=1,source_hash=digest(__file__),native_hash=digest(NATIVE),
        evaluator_hash=digest(REPO/"scripts/continuous-official-search.lisp"),
        mother_hash=SOURCE_HASH,scope=args.scope,smoke=args.smoke,
        directions=2 if args.smoke else args.directions,sigmas=list(SIGMAS),stage_counts=counts,seeds=seeds,
        total_existing_constants=len(parameters),eligible_constants=len(eligible),
        parameter_kinds=dict(Counter(p["kind"] for p in parameters.values())),
        units="max(0.05, min(5, 0.1*abs(initial_value)))",workers=args.workers,
        gradient="antithetic Gaussian ES estimate for a smoothed seed-averaged objective; not backpropagation",
        structure="Original graph, instructions, opcodes, registers, sources, terminals and Controller are frozen.",
        formal_promotion=False)
    save(path,value);return value

def stages(root,stage_name,protocol,mother,models,workers,budget):
    folder=root/stage_name;folder.mkdir(exist_ok=True)
    seeds=protocol["seeds"][stage_name]
    cases=[(100,s) for s in seeds]
    cost=len(cases)*100*(1+len(models))
    if budget["completed"]+cost>budget["limit"]:raise RuntimeError("Official budget would be exceeded")
    groups=[{"baseline":mother}]
    pairs=list(models.items())
    groups += [dict(pairs[i:i+3]) for i in range(0,len(pairs),3)]
    log(root,"EVALUATE",stage=stage_name,candidates=len(models),episodes=len(seeds),transitions=cost)
    def work(item):
        i,arms=item
        worker=folder/f"worker-{i:03}"
        if (worker/"trace.tsv").exists() and not (worker/"complete.json").exists():
            raise RuntimeError("Partial evidence must be inspected before retry: "+str(worker))
        return evaluate_job("b_line",worker,cases,arms)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        output=list(pool.map(work,enumerate(groups)))
    report=stage_report(output,models)
    save(folder/"results.json",report)
    budget["completed"]+=cost
    save(root/"budget.json",budget)
    log(root,"EVALUATED",stage=stage_name,cumulative=budget["completed"])
    return report,output

def active_coordinates(discovery,parameters):
    nodes=set()
    for folder in discovery:
        for r in rows(folder/"trace.tsv"):
            if r["arm"]!="baseline" or r["native_path"]=="OPENING":continue
            teams=[int(v) for v in re.findall(r'"TEAM-0-(\d+)"',r["native_path"])]
            nodes.update(v-teams[0] for v in teams)
    return sorted(i for i,p in parameters.items() if p["eligible"] and p["node"] in nodes),nodes

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--scope",choices=("all","active"),required=True)
    p.add_argument("--output",required=True);p.add_argument("--workers",type=int,default=3)
    p.add_argument("--directions",type=int,default=16);p.add_argument("--smoke",action="store_true")
    p.add_argument("--budget",type=int,default=96000)
    args=p.parse_args()
    root=Path(args.output).resolve();root.mkdir(parents=True,exist_ok=True)
    output_lock=(root/"study.lock").open("a")
    fcntl.flock(output_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    mother,parameters=initialize(root)
    protocol=plan(root,args,parameters)
    budget=dict(limit=args.budget,completed=0)
    # Exact-copy roundtrip checks the serializer with no new instructions.
    identity_root=root/"identity-build";identity_root.mkdir(exist_ok=True)
    identities=build_models(identity_root,mother,{"identity":dict(patch=[])})
    identity_cases=[(100,s) for s in protocol["seeds"]["discovery"]]
    identity=evaluate_job("b_line",root/"discovery"/"paired",identity_cases,
                          {"baseline":mother,"identity":identities["identity"]})
    trajectories=defaultdict(list)
    for r in rows(identity/"trace.tsv"):
        trajectories[r["seed"],r["arm"]].append(tuple(r[k] for k in ("step","obs","mask","concrete","reward","pair","top8")))
    for seed in protocol["seeds"]["discovery"]:
        assert trajectories[str(seed),"baseline"]==trajectories[str(seed),"identity"]
    budget["completed"]=len(identity_cases)*100*2
    assert budget["completed"]<=budget["limit"]
    save(root/"budget.json",budget)
    active,nodes=active_coordinates([identity],parameters)
    all_ids=sorted(i for i,p in parameters.items() if p["eligible"])
    ids=all_ids if args.scope=="all" else active
    assert ids
    save(root/"coordinates.json",dict(scope=args.scope,selected_ids=ids,active_ids=active,
         visited_nodes=sorted(nodes),selected_kinds=dict(Counter(parameters[i]["kind"] for i in ids)),
         original_values={str(i):parameters[i]["value"] for i in ids},units={str(i):parameters[i]["unit"] for i in ids}))
    log(root,"READY",scope=args.scope,parameters=len(ids),observed_active=len(active),directions=protocol["directions"])
    # Draw full-vector directions before projection so common coordinates match.
    generator=random.Random(202611190150 if not args.smoke else 202611190151)
    full_index={p:i for i,p in enumerate(all_ids)}
    directions=[]
    for _ in range(protocol["directions"]):
        vector=[generator.gauss(0,1) for i in all_ids]
        directions.append([vector[full_index[i]] for i in ids])
    proposed={}
    for si,sigma in enumerate(SIGMAS):
        for j,u in enumerate(directions):
            for sign,label in ((1,"plus"),(-1,"minus")):
                name=f"s{si}-d{j:02}-{label}"
                vector=[sign*sigma*x for x in u]
                proposed[name]=dict(kind="random-antithetic",sigma=sigma,direction=j,sign=sign,
                                    patch=physical_patch(ids,vector,parameters))
    probe_root=root/"probe-build";probe_root.mkdir(exist_ok=True)
    models=build_models(probe_root,mother,proposed)
    screening,_=stages(root,"probe",protocol,mother,models,args.workers,budget)
    validation_specs={}
    gradients={}
    for si,sigma in enumerate(SIGMAS):
        plus=[screening[f"s{si}-d{j:02}-plus"]["100"]["mean"] for j in range(len(directions))]
        minus=[screening[f"s{si}-d{j:02}-minus"]["100"]["mean"] for j in range(len(directions))]
        gradient=antithetic_gradient(directions,plus,minus,sigma)
        step=step_for_gradient(gradient,sigma)
        gradients[str(sigma)]=dict(estimate=gradient,norm=norm(gradient),
            nonzero_paired_directions=sum(abs(p-n)>1e-9 for p,n in zip(plus,minus)),plus=plus,minus=minus)
        names=[k for k in models if k.startswith(f"s{si}-")]
        best=max(names,key=lambda k:screening[k]["100"]["mean"])
        validation_specs[f"s{si}-best-random"]=dict(kind="best-random",source=best,patch=proposed[best]["patch"])
        if norm(step)>1e-12:
            for label,move in (("gradient",step),("opposite",[-x for x in step]),
                               ("matched-random",matched_random_step(random.Random(202611190170+si),step))):
                validation_specs[f"s{si}-{label}"]=dict(kind=label,sigma=sigma,step_norm=norm(move),
                                                       patch=physical_patch(ids,move,parameters))
        log(root,"DIRECTION",sigma=sigma,gradient_norm=norm(gradient),
            informative_directions=gradients[str(sigma)]["nonzero_paired_directions"])
    save(root/"gradients.json",gradients)
    validation_root=root/"validation-build";validation_root.mkdir(exist_ok=True)
    validation_models=build_models(validation_root,mother,validation_specs)
    validated,validation_folders=stages(root,"validation",protocol,mother,validation_models,args.workers,budget)
    # Compare forward/opposite/matched random on exactly the same fresh seeds.
    checks={}
    for si,sigma in enumerate(SIGMAS):
        checks[str(sigma)]={k:validated[k]["100"] for k in validation_models if k.startswith(f"s{si}-")}
    by_seed={}
    for folder in validation_folders:
        for row in rows(folder/"returns.tsv"):
            by_seed[int(row["seed"]),row["arm"]]=number(row["return"])
    direct={}
    for si,sigma in enumerate(SIGMAS):
        forward=f"s{si}-gradient"
        if forward not in validation_models:continue
        direct[str(sigma)]={}
        for control in ("baseline",f"s{si}-opposite",f"s{si}-matched-random",f"s{si}-best-random"):
            delta=[by_seed[seed,forward]-by_seed[seed,control] for seed in protocol["seeds"]["validation"]]
            direct[str(sigma)][forward+" - "+control]=stats(delta)
    save(root/"direction-check.json",dict(versus_mother=checks,paired_controls=direct))
    selected=sorted((k for k in validation_models if validated[k]["100"]["mean"]>1e-8
                     and not validated[k]["100"]["new_catastrophes"]),
                    key=lambda k:-validated[k]["100"]["mean"])[:2]
    confirmed={}
    if selected:
        confirmed,_=stages(root,"confirmation",protocol,mother,{k:validation_models[k] for k in selected},args.workers,budget)
    else:
        log(root,"NO_POSITIVE_VALIDATION",note="No additional official confirmation allocated")
    save(root/"results.json",dict(scope=args.scope,parameters=len(ids),informative_directions={
        k:v["nonzero_paired_directions"] for k,v in gradients.items()},
        validation=validated,paired_controls=direct,confirmation=confirmed,transitions=budget["completed"],
        promotion_performed=False,protected_mother_sha=digest(mother)))
    assert digest(mother)==SOURCE_HASH
    (root/"DONE").write_text("done\n")
    log(root,"DONE",transitions=budget["completed"],scope=args.scope)

if __name__=="__main__":
    main()


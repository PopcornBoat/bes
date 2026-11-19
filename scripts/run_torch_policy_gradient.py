"""Bounded native-controller / PyTorch terminal policy-gradient feasibility trial."""
from collections import defaultdict
import argparse
import fcntl
import json
from pathlib import Path
import random
import shutil
from continuous_official_search import REPO,digest,read,save,rows,number,run_lisp,evaluate_job,stage_report,sexp
from numeric_policy_tuning import sx
from replicate_search_lineage import previous_seeds
from torch_policy_assets import ROOT,SOURCE,prepare

SOURCE_HASH="cda3f1d75bdec6a6622974af492d4396753f427619d41afcd93d3509a9e12994"
ROOT_SEEDS=(202611190801,202611190802)

def log(root,message):
    print(message,flush=True)
    with (root/"events.log").open("a") as f:f.write(message+"\n")

def shared_plan(smoke):
    path=ROOT/("smoke-plan.json" if smoke else "training-plan.json")
    lock=(ROOT/(path.name+".lock")).open("a")
    with lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        if path.exists():return read(path)
        roots={}
        excluded,files=previous_seeds(ROOT)
        updates,batch,warm,check=(2,2,2,2) if smoke else (32,8,16,12)
        for ri,seedroot in enumerate(ROOT_SEEDS[:1] if smoke else ROOT_SEEDS):
            rng=random.Random(seedroot)
            offset=ri*50_000_000+(90_000_000 if smoke else 0)
            def block(stage,n):
                low=1_910_000_000+offset+stage*10_000_000
                result=[]
                while len(result)<n:
                    value=rng.randrange(low,low+9_000_000)
                    if value not in excluded and value not in result:
                        result.append(value);excluded.add(value)
                return result
            warmup=block(0,warm);training=block(1,updates*batch)
            evaluation=block(2,check*(1 if smoke else updates//4))
            confirm=block(3,2 if smoke else 100)
            every=2 if smoke else 4
            roots[str(seedroot)]=dict(
                warmup=[[s,rng.randrange(2**63)] for s in warmup],
                batches=[[[s,rng.randrange(2**63)] for s in training[i:i+batch]]
                         for i in range(0,len(training),batch)],
                checks={str(u):evaluation[i*check:(i+1)*check]
                        for i,u in enumerate(range(every,updates+1,every))},
                confirmation=confirm)
        value=dict(schema=1,smoke=smoke,roots=roots,updates=updates,batch=batch,warmup=warm,
            check_episodes=check,excluded_request_files=files,temperature=0.25,epsilon=0.01,
            actor_lr=0.02,max_normalized_change=0.5,kl_limit=0.02,
            learning_method="Terminal categorical REINFORCE with a training-only value baseline",
            expected_training_and_checks=(
                len(roots)*2*(warm+updates*batch)*100+
                len(roots)*(1 if smoke else updates//4)*check*2*100))
        save(path,value);return value

def training_form(mother,graph,catalog,plan_file,folder,mode,seed):
    files=("numeric-policy-parameters.lisp","torch-terminal-training.lisp")
    loads=" ".join("(load "+sx(str(REPO/"scripts"/f))+")" for f in files)
    args=(str(mother),str(graph),str(catalog),str(plan_file),str(folder)+"/",mode,seed,str(REPO/"scripts"))
    return "(progn "+loads+" (cl-tpg::torch-run-training "+" ".join(sx(a) for a in args)+"))"

def exported_rank_parity(folder,graph,catalog):
    import torch
    from torch_terminal_actor import FixedTPG,parameter_table
    model=FixedTPG(read(graph),parameter_table(catalog))
    count=0
    for snapshot in sorted(folder.glob("snapshot-*")):
        if not (snapshot/"trace.tsv").exists():continue
        state=torch.load(str(snapshot/"patch.sexp")+".pt",map_location="cpu",weights_only=True)
        assert state["ids"]==model.ids
        with torch.no_grad():model.x.copy_(state["x"])
        model.sync();expectations={}
        for row in rows(snapshot/"trace.tsv"):
            if row["arm"]!="candidate" or int(row["step"])<3:continue
            previous=expectations.setdefault(row["obs"],row["top8"])
            assert previous==row["top8"], "Stateless checkpoint ranking changed on identical input"
        for obs,expected in expectations.items():
            actual,_,_=model.ranking([int(c) for c in obs])
            assert actual==[tuple(map(int,p.split(":"))) for p in expected.split(";")]
            count+=1
    save(folder/"export-parity.json",dict(verified_rankings=count,new_official_transitions=0))
    return count

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--mode",choices=("learn","frozen"),required=True)
    p.add_argument("--root-index",type=int,choices=(0,1),default=0)
    p.add_argument("--smoke",action="store_true")
    p.add_argument("--parity-env",action="store_true")
    args=p.parse_args()
    ROOT.mkdir(parents=True,exist_ok=True)
    graph,catalog=prepare(ROOT)
    plan=shared_plan(args.smoke)
    seedroot=ROOT_SEEDS[args.root_index]
    cell=plan["roots"][str(seedroot)]
    folder=ROOT/("smoke" if args.smoke else "full")/f"root-{seedroot}"/args.mode
    folder.mkdir(parents=True,exist_ok=True)
    lock=(folder/"trial.lock").open("a");fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    assert digest(SOURCE)==SOURCE_HASH
    mother=folder/"mother.lisp"
    if not mother.exists():shutil.copyfile(SOURCE,mother);mother.chmod(0o444)
    assert digest(mother)==SOURCE_HASH
    manifest=dict(mother=SOURCE_HASH,graph=digest(graph),parameters=digest(catalog),mode=args.mode,
        seedroot=seedroot,protocol=plan,source=digest(REPO/"scripts/torch_terminal_actor.py"),
        native=digest(REPO/"scripts/torch-terminal-training.lisp"),
        final_evaluation="Original deterministic Lisp checkpoint, no probability sampling")
    manifest["runner"]=digest(__file__)
    if (folder/"manifest.json").exists():
        assert read(folder/"manifest.json")==manifest, "Refuse to change a recorded trial protocol"
    else:
        save(folder/"manifest.json",manifest)
    native_plan=folder/"requests.sexp"
    requests=[":warmup",cell["warmup"],":batches",cell["batches"],":checks",
              [[int(k),*v] for k,v in cell["checks"].items()]]
    # Write keyword plist separately so the general scalar encoder does not quote keywords.
    native_plan.write_text("(:warmup "+sx(requests[1])+" :batches "+sx(requests[3])+" :checks "+sx(requests[5])+")\n")
    if (folder/"DONE").exists():
        log(folder,"ALREADY_DONE");return
    if not (folder/"training-complete.json").exists():
        if (folder/"episodes.jsonl").exists():
            raise RuntimeError("Partial training evidence preserved; no automatic rerun of official interactions")
        log(folder,f"START mode={args.mode} root={seedroot} updates={plan['updates']} batch={plan['batch']}")
        run_lisp(training_form(mother,graph,catalog,native_plan,folder,args.mode,seedroot),folder/"trainer")
        save(folder/"training-complete.json",dict(mode=args.mode,updates=plan["updates"]))
    episode_records=[json.loads(l) for l in (folder/"episodes.jsonl").open()]
    assert len(episode_records)==plan["warmup"]+plan["updates"]*plan["batch"]
    spent=len(episode_records)*100
    # Greedy warmup must exactly reproduce native hard mother actions.
    if args.parity_env:
        warmseeds=[s for s,_ in cell["warmup"]]
        reference=evaluate_job("b_line",folder/"hard-parity",[(100,s) for s in warmseeds],{"baseline":mother})
        expected={}
        for r in rows(reference/"trace.tsv"):
            expected[int(r["seed"]),int(r["step"])]=r
        checked=0
        for line in (folder/"torch-trajectories.jsonl").open():
            r=json.loads(line)
            if r["phase"]!="warmup":continue
            original=expected[r["seed"],r["step"]]
            assert r["obs"]==original["obs"] and int(r["mask"])==int(original["mask"])
            assert r["concrete"]==int(original["concrete"])
            assert abs(r["reward"]-number(original["reward"]))<1e-7
            checked+=1
        save(folder/"hard-parity/results.json",dict(matched_transitions=checked))
        spent+=len(warmseeds)*100
        log(folder,f"HARD_PARITY_PASS transitions={checked}")
    snapshots={}
    for snap in sorted(folder.glob("snapshot-*")):
        if not (snap/"returns.tsv").exists():continue
        report=stage_report([snap],{"candidate":str(snap/"candidate.lisp")})
        snapshots[snap.name]=report["candidate"]["100"]
        spent+=2*plan["check_episodes"]*100
    save(folder/"hard-checks.json",snapshots)
    if args.mode=="learn":
        verified=exported_rank_parity(folder,graph,catalog)
        log(folder,f"EXPORT_RANK_PARITY_PASS contexts={verified}")
    confirmation={}
    if args.mode=="learn" and not args.smoke:
        best=max(snapshots,key=lambda k:snapshots[k]["mean"])
        candidates={"final":folder/"final/candidate.lisp","best":folder/best/"candidate.lisp"}
        if digest(candidates["final"])==digest(candidates["best"]):candidates.pop("best")
        job=evaluate_job("b_line",folder/"confirmation",[(100,s) for s in cell["confirmation"]],
                         {"baseline":mother,**candidates})
        confirmation=stage_report([job],candidates)
        spent+=100*len(cell["confirmation"])*(1+len(candidates))
        log(folder,"CONFIRMATION "+json.dumps({k:{f:v for f,v in c["100"].items()
                                                if f in ("mean","se","lower","upper","new_catastrophes")}
                                              for k,c in confirmation.items()}))
    updates=[json.loads(l) for l in (folder/"updates.jsonl").open()]
    assert digest(mother)==SOURCE_HASH
    if args.mode=="frozen":
        assert all(u["frozen"] for u in updates)
    result=dict(mode=args.mode,seedroot=seedroot,updates=updates,snapshots=snapshots,
                confirmation=confirmation,transitions=spent,protected_mother=SOURCE_HASH,
                formal_promotion=False)
    expected_max=(plan["warmup"]+plan["updates"]*plan["batch"])*100
    if args.mode=="learn":
        expected_max+=len(cell["checks"])*plan["check_episodes"]*200
        if not args.smoke:expected_max+=len(cell["confirmation"])*300
    if args.parity_env:expected_max+=plan["warmup"]*100
    assert spent<=expected_max
    result["maximum_transitions"]=expected_max
    save(folder/"results.json",result)
    (folder/"DONE").write_text("done\n")
    log(folder,f"DONE transitions={spent} mode={args.mode} root={seedroot}")

if __name__=="__main__":
    main()


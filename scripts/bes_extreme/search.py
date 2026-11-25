#!/usr/bin/env python3
"""Bounded official-score optimization for a frozen BES Controller + TPG bundle."""
import argparse
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import fcntl
import hashlib
from itertools import combinations, islice, permutations, product, zip_longest
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys
import time

from evaluate import (EVALUATION_FILES, HERE, HOSTS, REDS, STEPS_PER_CELL_SET, SUPPORT,
                      bundle_config, code_hashes, compile_candidate, evaluator, read, save, sha)

EPSILON = 1e-9
SCHEMA = "bes-extreme-optimize-v1"


def key(data):
    return hashlib.sha256(json.dumps(data,sort_keys=True,separators=(",",":")).encode()).hexdigest()


@dataclass
class Policy:
    table: dict
    graphs: dict
    graph_sha256: dict

    def change_table(self, **orders):
        return Policy({**self.table,**orders},self.graphs,self.graph_sha256)

    def change_graph(self, role, path):
        return Policy(self.table,{**self.graphs,role:str(path)},{**self.graph_sha256,role:sha(path)})


def permutations_for(order):
    prior = tuple(order)
    for other in permutations(prior):
        if other != prior:
            yield list(other)


def single_moves(parent, hosts, budget):
    """Interleave hosts so a bounded budget does not all go to the first one."""
    def slot(host):
        return ((host,order) for order in permutations_for(parent.table[host]))
    ordered = (move for group in zip_longest(*(slot(host) for host in hosts))
               for move in group if move is not None)
    return list(islice(ordered,budget))


def combined_moves(rows, baseline, limit, per_host):
    winners = defaultdict(list)
    for host,order,total in sorted(rows,key=lambda r:(-r[2],r[0],r[1])):
        if total>baseline+EPSILON and len(winners[host])<per_host:
            winners[host].append((order,total))
    choices = []
    for a,b in combinations(winners,2):
        for ((x,score_x),(y,score_y)) in product(winners[a],winners[b]):
            choices.append((-(score_x+score_y), {a:x,b:y}))
    choices.sort(key=lambda item:(item[0],sorted(item[1].items())))
    return [move for _,move in choices[:limit]]


def improves(candidate, parent):
    return candidate["total"]>parent["total"]+EPSILON


def holdout_check(pairs, tolerance):
    """Use full roots as the comparison unit under continuous resets."""
    roots = []
    for root,base,trial in pairs:
        differences = {cell:trial["cells"][cell]["mean"]-stats["mean"]
                       for cell,stats in base["cells"].items()}
        tails = {f"100-{red}": trial["cells"][f"100-{red}"]["below_minus100"]
                 -base["cells"][f"100-{red}"]["below_minus100"]
                 for red in REDS if red!="SleepAgent"}
        roots.append(dict(root=root,baseline=base["total"],candidate=trial["total"],
                          gain=trial["total"]-base["total"],mean_gain_by_cell=differences,
                          below_minus100_delta=tails,
                          cvar10_delta={cell:trial["cells"][cell]["cvar10"]-base["cells"][cell]["cvar10"]
                                        for cell in tails}))
    mean = sum(row["gain"] for row in roots)/len(roots)
    approved = (mean>=-tolerance-EPSILON and
                all(n<=0 for row in roots for n in row["below_minus100_delta"].values()))
    return dict(accepted=approved,mean_gain=mean,tolerance=tolerance,roots=roots)


class Evaluations:
    def __init__(self, output, bundle, environment_hash, episodes, workers, lock_fd):
        self.output=output
        self.bundle=bundle
        self.environment_hash=environment_hash
        self.episodes=episodes
        self.workers=workers
        self.lock_fd=lock_fd

    def evaluate(self, policy, root, nominate=False):
        request=dict(bundle=str(self.bundle),root=root,episodes=self.episodes,table=policy.table,
                     graphs=policy.graphs,graph_sha256=policy.graph_sha256,nominate=nominate,
                     environment_sha256=self.environment_hash)
        signature=key(request)
        job=self.output/"jobs"/f"{root}-{signature[:20]}"
        evidence=job/"evaluation"
        request["output"]=str(evidence)
        job.mkdir(parents=True,exist_ok=True)
        completed=evidence/"complete.json"
        reused=completed.exists()
        if reused:
            marker=read(completed)
            files=EVALUATION_FILES + (("nominees.json",) if nominate else ())
            if (marker["request"]!=request or
                    marker["files_sha256"]!={name:sha(evidence/name) for name in files}):
                raise RuntimeError(f"Archived result changed: {job}")
        else:
            if any(job.iterdir()):
                previous=job.with_name(job.name+f".previous-{time.time_ns()}")
                job.rename(previous)
                job.mkdir()
            save(job/"request.json",request)
            with (job/"worker.log").open("w",encoding="utf-8") as stream:
                # An evaluator still owns the run while finishing after a parent interruption.
                process=subprocess.run([sys.executable,"-B",str(HERE/"evaluate.py"),str(job/"request.json")],
                                       stdout=stream,stderr=subprocess.STDOUT,pass_fds=(self.lock_fd,))
            if process.returncode or not completed.exists():
                raise RuntimeError(f"Official evaluation failed: {job/'worker.log'}")
        result=read(evidence/"results.json")
        print(f'{"REUSE" if reused else "EVAL"} {job.name} total={result["total"]:+.4f}'
              f'{" trace" if nominate else ""}',flush=True)
        return {**result,"evidence": str(evidence)}

    def batch(self, policies, root):
        if not policies:
            return []
        with ThreadPoolExecutor(max_workers=self.workers) as pool:
            return list(pool.map(lambda p:self.evaluate(p,root),policies))


def initial(bundle, cfg):
    return Policy(cfg["table"],{k:str(bundle/"inputs"/v["file"]) for k,v in cfg["input_sha256"].items()},
                  {k:v["sha256"] for k,v in cfg["input_sha256"].items()})


def archive_policy(output, bundle, cfg, policy, name="best-policy"):
    destination=output/name
    new={k:cfg[k] for k in ("version","cyborg_commit","official_script_sha256","controller_sha256",
                            "fixed_opening","decoy_resolution")}
    new.update(table=policy.table,input_sha256={
        k:{"file":f"{k}.lisp","sha256":digest} for k,digest in policy.graph_sha256.items()})
    # This bundle uses the maintained runtime and the selected table manifest.
    if destination.exists():
        if bundle_config(destination)!=new:
            raise RuntimeError("Existing published policy differs. Use a new search directory.")
        return destination
    staging=output/f".{name}-{time.time_ns()}"
    shutil.copytree(bundle/"code",staging/"code",ignore=shutil.ignore_patterns("__pycache__","*.pyc"))
    (staging/"support").mkdir()
    for item in SUPPORT:
        shutil.copyfile(bundle/"support"/item,staging/"support"/item)
    (staging/"inputs").mkdir()
    for role,path in policy.graphs.items():
        shutil.copyfile(path,staging/"inputs"/new["input_sha256"][role]["file"])
    save(staging/"policy.json",new)
    assert bundle_config(staging)==new
    staging.rename(destination)
    return destination


def graph_moves(args, bundle, lead, nominations):
    moves=[]
    unsupported=set()
    for evidence in nominations:
        role = "b_line" if evidence["route"]=="bline" else "meander"
        if role in unsupported:
            continue
        digest=key([lead.graph_sha256[role],evidence])
        candidate=args.output/"graphs"/f"{role}-{digest[:20]}.lisp"
        proof=candidate.with_suffix(".verified.json")
        if proof.exists():
            if read(proof)!={"proposal":digest,"graph_sha256":sha(candidate)}:
                raise RuntimeError(f"Archived graph candidate changed: {candidate}")
        else:
            if candidate.exists():
                candidate.rename(candidate.with_name(candidate.name+f".previous-{time.time_ns()}"))
            if not compile_candidate(bundle,lead.graphs[role],evidence,candidate):
                unsupported.add(role)
                continue
            save(proof,{"proposal":digest,"graph_sha256":sha(candidate)})
        moves.append((lead.change_graph(role,candidate),evidence))
        if len(moves)>=args.graph_budget:
            break
    return moves


def rounds(args, original, jobs):
    parent=original
    baseline=jobs.evaluate(parent,args.root)
    parent_score=baseline
    history=[]
    for round_number in range(1,args.rounds+1):
        accepted = []
        singles=single_moves(parent,args.hosts,args.single_budget)
        variants=[parent.change_table(**{host:order}) for host,order in singles]
        outcomes=jobs.batch(variants,args.root)
        eligible=[(h,o,r["total"]) for (h,o),r in zip(singles,outcomes)]
        joints=combined_moves(eligible,parent_score["total"],args.joint_budget,args.joint_width)
        added=[parent.change_table(**orders) for orders in joints]
        joint_results=jobs.batch(added,args.root)
        lead,score=parent,parent_score
        entries=[("single-host",dict(host=h,order=o),p,r)
                 for (h,o),p,r in zip(singles,variants,outcomes)]
        entries += [("combined-hosts",move,p,r) for move,p,r in zip(joints,added,joint_results)]
        tested=[]
        for family,move,policy,result in entries:
            tested.append(dict(family=family,change=move,total=result["total"],evidence=result["evidence"]))
            if improves(result,score):
                lead,score=policy,result

        if improves(score,parent_score):
            accepted.append(dict(family="decoy",total=score["total"],table=lead.table))
        if args.graph_budget:
            traced=jobs.evaluate(lead,args.root,nominate=True)
            assert abs(traced["total"]-score["total"])<=EPSILON
            for name in ("actions.tsv","episodes.tsv"):
                if sha(Path(traced["evidence"])/name)!=sha(Path(score["evidence"])/name):
                    raise RuntimeError(f"Nomination changed the official trace: {name}")
            proposals=graph_moves(args,jobs.bundle,lead,read(Path(traced["evidence"])/"nominees.json"))
            options=jobs.batch([candidate for candidate,_ in proposals],args.root)
            for (policy,evidence),result in zip(proposals,options):
                tested.append(dict(family="ranked-graph",change=evidence,total=result["total"],
                                   evidence=result["evidence"]))
                if improves(result,score):
                    lead,score=policy,result
                    accepted.append(dict(family="ranked-graph",total=score["total"],change=evidence))

        history.append(dict(round=round_number,initial=parent_score["total"],best=score["total"],
                            tested=tested,updates=accepted))
        save(args.output/"rounds.json",history)
        print(f"ROUND {round_number} {parent_score['total']:+.4f} -> {score['total']:+.4f}; "
              f"candidates={len(tested)}",flush=True)
        if not improves(score,parent_score):
            break
        parent,parent_score=lead,score
    return parent,baseline,parent_score,history


def execute(args, cfg, budget, lock_fd):
    source=initial(args.bundle,cfg)
    _,fingerprint=evaluator(cfg)
    plan={"schema":SCHEMA,"bundle":str(args.bundle),"root":args.root,
          "holdout_roots":args.holdout,"episodes":args.episodes,"rounds":args.rounds,
          "hosts":args.hosts,"single_budget":args.single_budget,"joint_budget":args.joint_budget,
          "joint_width":args.joint_width,"graph_budget":args.graph_budget,
          "holdout_tolerance":args.holdout_tolerance,"max_transitions":budget,
          "evaluate_only":args.evaluate_only,"input":cfg,"source_sha256":code_hashes(args.bundle),
          "environment_sha256":fingerprint}
    manifest=args.output/"manifest.json"
    if manifest.exists():
        if read(manifest)!=plan:
            raise ValueError("Run settings or fingerprints changed. Use a new output directory.")
    else:
        if any(p.name!=".lock" for p in args.output.iterdir()):
            raise ValueError("Output is not empty and has no extreme-optimize manifest.")
        save(manifest,plan)

    pinned=archive_policy(args.output,args.bundle,cfg,source,name="source-policy")
    frozen_cfg=bundle_config(pinned)
    if code_hashes(pinned)!=plan["source_sha256"]:
        raise ValueError("Frozen BES source tree differs from the input used to create this run")
    source=initial(pinned,frozen_cfg)
    jobs=Evaluations(args.output,pinned,fingerprint,args.episodes,args.workers,lock_fd)
    if args.evaluate_only:
        selected=source
        original=best=jobs.evaluate(source,args.root)
        history=[]
        outcome="evaluated"
        holdout=None
    else:
        selected,original,best,history=rounds(args,source,jobs)
        holdout=None
        if improves(best,original):
            pairs=[(root,*jobs.batch([source,selected],root)) for root in args.holdout]
            holdout=holdout_check(pairs,args.holdout_tolerance)
            outcome="validated" if holdout["accepted"] else "holdout-rejected"
        else:
            outcome="no-gain"

    published=selected if outcome in ("validated","evaluated") else source
    path=archive_policy(args.output,pinned,frozen_cfg,published)
    completed=list((args.output/"jobs").glob("*/evaluation/complete.json"))
    steps=sum(read(marker.with_name("results.json"))["steps"] for marker in completed)
    save(args.output/"result.json",dict(status=outcome,root=args.root,episodes_per_cell=args.episodes,
         baseline=original["total"],fixed_root_best=best["total"],
         baseline_evidence=original["evidence"],fixed_root_evidence=best["evidence"],
         fixed_root_candidate={"table":selected.table,"graph_sha256":selected.graph_sha256,
                               "graphs":selected.graphs},
         round_count=len(history),holdout=holdout,published_policy=str(path),
         completed_evaluations=len(completed),completed_transitions=steps))
    print(f"{outcome}: {original['total']:+.4f} -> {best['total']:+.4f} on root {args.root}",flush=True)


def nonnegative(value):
    n=int(value)
    if n<0:
        raise argparse.ArgumentTypeError("Expected a non-negative integer")
    return n


def positive(value):
    n=nonnegative(value)
    if not n:
        raise argparse.ArgumentTypeError("Expected a positive integer")
    return n


def root_value(value):
    n=nonnegative(value)
    if n>=2**32:
        raise argparse.ArgumentTypeError("Expected a seed root smaller than 2^32")
    return n


def roots(value):
    values=[root_value(v) for v in value.split(",")]
    if len(set(values))!=len(values):
        raise argparse.ArgumentTypeError("Seed roots must be distinct")
    return values


def hosts(value):
    values=value.split(",")
    if len(set(values))!=len(values) or any(h not in HOSTS for h in values):
        raise argparse.ArgumentTypeError("Expected distinct Controller host names")
    return values


def budget_for(args):
    runs=1 if args.evaluate_only else (1+args.rounds*(
        args.single_budget+args.joint_budget+args.graph_budget+int(bool(args.graph_budget)))+2*len(args.holdout))
    return runs*args.episodes*STEPS_PER_CELL_SET


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle",type=Path,required=True,help="Frozen pure-graph official BES bundle")
    parser.add_argument("--output",type=Path,required=True,help="New run directory, or resume an unchanged run")
    parser.add_argument("--root",type=root_value,default=153,help="Score-optimization root")
    parser.add_argument("--holdout",type=roots,default=[42,290150561],help="Comma-separated holdout roots")
    parser.add_argument("--episodes",type=positive,default=1000,help="Official episodes per horizon and opponent")
    parser.add_argument("--rounds",type=positive,default=1)
    parser.add_argument("--hosts",type=hosts,default=list(HOSTS),
                        help="Comma-separated Decoy hosts to consider")
    parser.add_argument("--single-budget",type=nonnegative,default=24,help="Maximum single-host variants per round")
    parser.add_argument("--joint-budget",type=nonnegative,default=8,help="Maximum joint variants per round")
    parser.add_argument("--joint-width",type=positive,default=4,help="Maximum improving single options per host")
    parser.add_argument("--graph-budget",type=nonnegative,default=2,help="Maximum exact ranked graph edits per round")
    parser.add_argument("--workers",type=positive,default=2)
    parser.add_argument("--holdout-tolerance",type=float,default=0.0,help="Allowed mean score drop on holdout roots")
    parser.add_argument("--max-transitions",type=positive,help="Reject a plan above this upper bound")
    parser.add_argument("--plan-only",action="store_true")
    parser.add_argument("--evaluate-only",action="store_true",help="Score one bundle as-is on the requested root")
    args=parser.parse_args()
    args.bundle=args.bundle.resolve()
    args.output=args.output.resolve()
    if args.output.is_relative_to(args.bundle) or args.bundle.is_relative_to(args.output):
        parser.error("Bundle and output directories must be disjoint")
    if args.episodes<2:
        parser.error("Use at least two episodes per cell for the official standard deviation")
    if not args.evaluate_only and args.root in args.holdout:
        parser.error("Selected score root must differ from holdout roots")
    if not math.isfinite(args.holdout_tolerance) or args.holdout_tolerance<0:
        parser.error("Holdout tolerance must be finite and non-negative")
    budget=budget_for(args)
    if args.max_transitions is not None and budget>args.max_transitions:
        parser.error(f"Planned upper bound {budget:,} exceeds --max-transitions")
    cfg=bundle_config(args.bundle)
    print(f"extreme-optimize root={args.root} episodes/cell={args.episodes} "
          f"plan-at-most={budget:,} transitions",flush=True)
    if args.plan_only:
        return
    args.output.mkdir(parents=True,exist_ok=True)
    with (args.output/".lock").open("a",encoding="utf-8") as lock:
        try:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("Output already has a running extreme-optimize process")
        execute(args,cfg,budget,lock.fileno())


if __name__=="__main__":
    main()

#!/usr/bin/env python3
"""Compare all 36 semantic proposal and delivered-action shares from archived runs."""
import argparse
from collections import Counter
import math
from pathlib import Path
import re

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
import numpy as np

from figures import BLUE, PURPLE, executed, read, save, semantic
from visualize_tpg import HOSTS, RESPONSES, csv_read, csv_write, dump, sha

STAGES = ("Top-1","Delivered")
STYLE = {"Top-1":"--","Delivered":"-"}
TASKS = ("B-line","Meander")
TITLES = {"B-line":"Explicit-seed v14 vs continuous final root 153",
          "Meander":"Six matched 100-step evaluation roots"}
PALETTES = {"B-line":{"B-line v14":BLUE,"Final B-line":PURPLE},
            "Meander":{"Final Meander":BLUE,"Pure Restore graph":PURPLE}}


def load_counts(root):
    index = read(root/"archive-index.json")
    code = Path(index["code"])
    # Match the declared vocabulary so a new Controller/action contract cannot
    # silently widen the 36-cell comparison.
    raw = (code/"action.lisp").read_text()
    targets = tuple(int(k) for k in re.search(r'\(defparameter \*semantic-36-targets\* #\(([^)]+)\)',raw)[1].split())
    pairs = [(HOSTS[k],r) for k in targets for r in RESPONSES]
    assert len(pairs)==len(set(pairs))==36
    bline = {}
    trace_info = next(s for s in read(Path(index["checkpoints"]["bline-v14"]["traces"]))
                      if "root-153/" in s["path"])
    legacy = Path(trace_info["path"])
    assert sha(legacy)==trace_info["source_sha256"]
    final = root/"evidence/final-root153-actions.tsv"
    actual_sha = read(root/"evidence/action-archive-sha256.json")["final-root153-actions.tsv"]
    assert sha(final)==actual_sha
    provenance = {
        "B-line v14":{"trace":str(legacy),"sha256":trace_info["source_sha256"],"episodes":1000,
                      "protocol":"historical explicit episode seeds derived from root 153"},
        "Final B-line":{"trace":str(final),"sha256":actual_sha,"episodes":1000,
                        "protocol":"official continuous root 153"},
    }
    top1,delivered = Counter(),Counter()
    for row in csv_read(legacy):
        if row["BEHAVIOR"]=="TPG" and row["HORIZON"]=="100" and int(row["STEP"])>=3:
            proposal = row["TPG_TOP8"].split(";")[0].replace(",",":")
            top1[semantic(proposal)]+=1
            delivered[executed(row["EXECUTED_CONCRETE"])]+=1
    bline["B-line v14"] = dict(zip(STAGES,(top1,delivered)))
    top1,delivered = Counter(),Counter()
    for row in csv_read(final):
        if row["red"]=="B_lineAgent" and row["horizon"]=="100" and int(row["step"])>=3:
            top1[semantic(row["native_top1"])]+=1
            delivered[executed(row["concrete"])]+=1
    bline["Final B-line"] = dict(zip(STAGES,(top1,delivered)))
    fresh = root/"evidence/graph-restore/results.json"
    by_root = read(fresh)["by_root"]
    assert len(by_root)==6
    meander = {}
    for policy,arm in (("Final Meander","native"),("Pure Restore graph","graph")):
        stages = {k:Counter() for k in STAGES}
        for row in by_root.values():
            cell = row[arm]["cell100"]
            assert cell["episodes"]==1000 and cell["post_opening_steps"]==97000
            for proposal,count in cell["top1"]["native_top1"].items():
                stages["Top-1"][semantic(proposal)]+=count
            for concrete,count in cell["concrete_counts"].items():
                stages["Delivered"][executed(concrete)]+=count
        meander[policy]=stages
        provenance[policy]={"trace":str(fresh),"sha256":sha(fresh),"arm":arm,"seed_roots":sorted(by_root),
                            "episodes":6000,"protocol":"official continuous repeated root"}
    counts = {"B-line":bline,"Meander":meander}
    for policies in counts.values():
        for policy,stages in policies.items():
            for category,table in stages.items():
                assert sum(table.values())==97*provenance[policy]["episodes"],(policy,category)
    return counts, pairs, provenance


def normalize(table):
    total = sum(table.values())
    return Counter({pair:n*100/total for pair,n in table.items()})


def make_axis(ax,axis_labels,values,title,tick):
    theta = np.linspace(0,2*np.pi,len(axis_labels),endpoint=False)
    top = tick*max(1,math.ceil(max((max(series) for series,_,_ in values),default=0)/tick))
    for series,color,stage in values:
        ax.plot(np.r_[theta,theta[0]],np.r_[series,series[0]],color=color,ls=STYLE[stage],
                linewidth=1.65,marker="o" if stage=="Delivered" else None,markersize=3,alpha=.94)
        if stage=="Delivered":
            ax.fill(np.r_[theta,theta[0]],np.r_[series,series[0]],color=color,alpha=.05)
    ax.set_theta_zero_location("N")
    ax.set_theta_direction(-1)
    ax.set_xticks(theta,axis_labels,fontsize=9)
    ax.set_ylim(0,top*1.035)
    locations = np.linspace(top/4,top,4)
    ax.set_yticks(locations,[f"{v:g}%" for v in locations],fontsize=7,color="#4A586A")
    ax.set_rlabel_position(23)
    ax.tick_params(axis="x",pad=7)
    ax.set_title(title,fontsize=11,pad=24)
    ax.grid(alpha=.25)


def legend(palette):
    return [Line2D([0],[0],color=c,lw=2,label=k) for k,c in palette.items()] + [
        Line2D([0],[0],color="#536274",linestyle=STYLE[stage],lw=1.7,label=stage) for stage in STAGES
    ]


def render_radars(root,counts,pairs):
    figures=root/"figures"
    hosts=list(dict.fromkeys(h for h,_ in pairs))
    for task in TASKS:
        palettes=PALETTES[task]
        policies=counts[task]
        rates={(k,s):normalize(t) for k,v in policies.items() for s,t in v.items()}
        slug="bline" if task=="B-line" else "meander"
        fig,ax=plt.subplots(figsize=(6.8,5.3),subplot_kw={"projection":"polar"},layout="constrained")
        values=[([sum(rates[p,s][h,r] for h in hosts) for r in RESPONSES],color,s)
                for p,color in palettes.items() for s in STAGES]
        make_axis(ax,RESPONSES,values,TITLES[task],20)
        fig.suptitle(f"{task}  |  Response mix",x=.025,ha="left",fontsize=17,weight="bold")
        fig.legend(handles=legend(palettes),loc="outside lower center",ncol=4,frameon=False,fontsize=8)
        save(fig,figures,f"{slug}-semantic-response-radar")

        fig,axs=plt.subplots(2,2,figsize=(10.5,9.6),subplot_kw={"projection":"polar"},layout="constrained")
        for ax,response in zip(axs.flat,RESPONSES):
            values=[([rates[p,s][h,response] for h in hosts],color,s)
                    for p,color in palettes.items() for s in STAGES]
            peak=max(max(vals) for vals,_,_ in values)
            tick=10 if peak>=15 else 4 if peak>=5 else 1
            make_axis(ax,[h.replace("Op_Server0","Op_Server0\n") for h in hosts],values,response,tick)
        fig.suptitle(f"{task}  |  Semantic action targeting\n{TITLES[task]}",
                     x=.02,ha="left",fontsize=16,weight="bold")
        fig.legend(handles=legend(palettes),loc="outside lower center",ncol=4,frameon=False,fontsize=9)
        save(fig,figures,f"{slug}-semantic-host-response-radar")

    fig,axs=plt.subplots(2,2,figsize=(10.4,7.8),layout="constrained")
    for row,task in enumerate(TASKS):
        reference,candidate=counts[task].values()
        arrays=[np.array([[normalize(candidate[s])[h,r]-normalize(reference[s])[h,r] for r in RESPONSES]
                          for h in hosts]) for s in STAGES]
        limit=max(.05,math.ceil(20*max(np.max(np.abs(m)) for m in arrays))/20)
        for col,(phase,values) in enumerate(zip(STAGES,arrays)):
            ax=axs[row,col]
            im=ax.imshow(values,aspect="auto",cmap="RdBu",vmin=-limit,vmax=limit)
            ax.set_title(f"{task}  |  {phase} change",fontsize=10)
            ax.set_xticks(range(len(RESPONSES)),RESPONSES)
            ax.set_yticks(range(len(hosts)),hosts)
            for y,x in np.ndindex(values.shape):
                value=values[y,x]
                ax.text(x,y,f"{value:+.2f}" if abs(value)>=.005 else "0.00",ha="center",va="center",fontsize=7,
                        color="white" if abs(value)>=.65*limit else "#162333")
        fig.colorbar(im,ax=axs[row,:],fraction=.025,label="Percentage points")
    fig.suptitle("Changes across all 36 semantic actions\nFinal B-line minus v14  |  Pure Restore graph minus Final Meander",
                 x=.02,ha="left",fontsize=15,weight="bold")
    save(fig,figures,"semantic-36-checkpoint-differences")


def publish(root):
    counts,pairs,provenance=load_counts(root)
    known=set(pairs)
    rows=[]
    cross=Counter()
    for task,policies in counts.items():
        for name,stages in policies.items():
            for stage,tally in stages.items():
                rates=normalize(tally)
                for h,r in [*pairs,*sorted(set(tally)-known)]:
                    included=(h,r) in known
                    rows.append(dict(task=task,checkpoint=name,stage=stage,host=h,response=r,in_semantic_36=included,
                                     count=tally[h,r],share_pct=rates[h,r],decisions=sum(tally.values())))
                    if not included:
                        cross[f"{task}/{name}/{stage}/{h}/{r}"]+=tally[h,r]
    csv_write(root/"semantic-36-checkpoint-radar.csv",rows,
              ["task","checkpoint","stage","host","response","in_semantic_36","count","share_pct","decisions"])
    dump(root/"semantic-36-checkpoint-radar-provenance.json",
         {"source":provenance,"outside_semantic_counts":cross,
          "measure":"Percent of post-opening decisions, evaluated at 100 steps",
          "comparability":"B-line differs in evaluation protocol; Meander pairs at root level.",
          "graph_only":"Only archived Controller plus serialized graph policy arms. Monitor is accounted for separately.",
          "causal_scope":"Counts measure usage, not the effectiveness of each action."})
    render_radars(root,counts,pairs)
    for task,p in counts.items():
        print(task,{name:{s:sum(t.values()) for s,t in st.items()} for name,st in p.items()},flush=True)


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report",type=Path,required=True)
    publish(parser.parse_args().report)

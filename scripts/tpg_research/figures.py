#!/usr/bin/env python3
"""Publish figures from archived BES outcomes and verified checkpoint replay."""
import argparse
from collections import Counter
from html import escape
import json
import re
from pathlib import Path
from statistics import mean

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.patches import Circle

from visualize_tpg import HOSTS, RESPONSES, csv_read, csv_write, dump, sha

BLUE, ORANGE, PURPLE, GREEN = "#4477AA", "#EE7733", "#AA5599", "#228833"
REDS = {"B_lineAgent":"B-line","RedMeanderAgent":"Meander"}
COLORS = dict(zip(("Analyse","Remove","Restore","Decoy","Monitor","Other"),
                  (BLUE,ORANGE,PURPLE,GREEN,"#667585","#AAAAAA")))
plt.rcParams.update({"font.size":10,"axes.spines.top":False,"axes.spines.right":False,
                     "pdf.fonttype":42,"svg.fonttype":"none","figure.facecolor":"white",
                     "axes.titlelocation":"left","axes.titleweight":"bold"})


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


FULL_HOSTS = (*HOSTS[1:5],"Op_Host0","Op_Host1","Op_Host2",*HOSTS[5:])


def executed(value):
    action = int(value)
    if action in (0,1):
        return "Global", ("Sleep" if action==0 else "Monitor")
    for base,end,response in ((2,15,"Analyse"),(15,28,"Remove"),(28,132,"Decoy"),(132,145,"Restore")):
        if base<=action<end:
            return FULL_HOSTS[(action-base)%13],response
    raise ValueError(f"Unexpected CAGE2 action {action}")


def save(fig,folder,name):
    for ext in ("svg","pdf","png"):
        fig.savefig(folder/f"{name}.{ext}",bbox_inches="tight",dpi=250,facecolor="white",pad_inches=.17)
    plt.close(fig)


def semantic(value):
    t,r = map(int,value.split(":"))
    return (HOSTS[t],RESPONSES[r]) if t else ("Global","Monitor")


def ring(axis,counts,colors):
    data=sorted(counts.items(),key=lambda x:(-x[1],x[0]))
    n=sum(counts.values())
    wedges,_=axis.pie([v for _,v in data],startangle=90,counterclock=False,
                      colors=[colors(k) for k,_ in data],
                      wedgeprops={"width":.69,"edgecolor":"white","linewidth":.6})
    for w,(_,v) in zip(wedges,data):
        angle=np.deg2rad((w.theta1+w.theta2)/2)
        if v/n>=.07:
            axis.text(.65*np.cos(angle),.65*np.sin(angle),f"{v/n:.0%}",color="white",
                      weight="bold",ha="center",va="center",fontsize=8)
    axis.text(0,0,f"{n:,}",ha="center",va="center",weight="bold",fontsize=9)
    return wedges,[k for k,_ in data]


def action_plots(root,index,figures):
    cardiff_source=Path(index["original_release"]).parents[1]/"runtime/full-agent-validation-20261120/full/cardiff/actions.tsv"
    sources={"BES":root/"evidence/final-root153-actions.tsv",
             "Cardiff":root/"evidence/cardiff-root153-actions.tsv"}
    if not sources["Cardiff"].exists():
        import shutil
        shutil.copyfile(cardiff_source,sources["Cardiff"])
    counts={(op,a,what):Counter() for op in REDS.values() for a in sources
            for what in (("executed","top1") if a=="BES" else ("executed",))}
    changes=Counter()
    for name,path in sources.items():
        for row in csv_read(path):
            if row["horizon"]!="100" or int(row["step"])<3 or row["red"] not in REDS:
                continue
            task=REDS[row["red"]]
            delivered=executed(row["concrete"])
            counts[task,name,"executed"][delivered]+=1
            if name=="BES":
                pick=semantic(row["native_top1"])
                counts[task,name,"top1"][pick]+=1
                changes[task," ".join(pick)," ".join(delivered)]+=1
    rows=[]
    for (task,policy,stage),c in counts.items():
        assert sum(c.values())==97000
        rows += [dict(task=task,policy=policy,stage=stage,host=h,response=r,n=n,rate=n/97000)
                 for (h,r),n in sorted(c.items())]
    csv_write(root/"action-frequency.csv",rows,["task","policy","stage","host","response","n","rate"])
    csv_write(root/"controller-transitions.csv",
              [dict(task=t,proposal=p,delivery=d,n=n) for (t,p,d),n in sorted(changes.items())],
              ["task","proposal","delivery","n"])
    for tag,title,columns in (
        ("tpg-wins-vs-execution","TPG winning proposals and actual execution",
         [("BES","top1","TPG Top-1"),("BES","executed","Controller executed")]),
        ("tpg-vs-ppo-response-pies","TPG / PPO response comparison",
         [("BES","executed","BES pure graph"),("Cardiff","executed","Cardiff 90000")]),
        ("host-response-decomposition","Host-response decomposition",
         [("BES","executed","BES pure graph"),("Cardiff","executed","Cardiff 90000")]),
    ):
        by_host=tag=="host-response-decomposition"
        fig,axs=plt.subplots(2,2,figsize=(10,7.2),layout="constrained")
        host_color=dict(zip(HOSTS,plt.get_cmap("tab20").colors))
        for i,task in enumerate(REDS.values()):
            for j,(policy,phase,label) in enumerate(columns):
                ax=axs[i,j]
                dist=Counter()
                for (h,a),n in counts[task,policy,phase].items():
                    key=(f"{h} / {a}" if n>=.025*97000 else "Other") if by_host else a
                    dist[key]+=n
                if by_host:
                    def shade(key):
                        if key=="Other":
                            return "#A8B2BB"
                        host,response=key.split(" / ")
                        weight={"Analyse":0,"Remove":.30,"Restore":.12,"Decoy":.21}.get(response,.25)
                        return tuple(x+(1-x)*weight for x in host_color.get(host,(.46,.51,.58)))
                    wedges,labels=ring(ax,dist,shade)
                    ax.legend(wedges,labels,loc="center left",bbox_to_anchor=(.95,.5),
                              fontsize=7,frameon=False)
                else:
                    ring(ax,dist,lambda k:COLORS.get(k,"#C6CDD6"))
                ax.set_title(f"{task}  |  {label}",fontsize=10)
        fig.suptitle(title,x=.02,ha="left",fontsize=16,fontweight="bold")
        if not by_host:
            handles=[plt.Line2D([],[],color=c,marker="o",linestyle="None",label=k) for k,c in COLORS.items()]
            fig.legend(handles=handles,loc="outside lower center",ncols=6,frameon=False)
        save(fig,figures,tag)

    fig,axs=plt.subplots(2,2,figsize=(10,7.4),layout="constrained",sharex=True,sharey=True)
    hosts=("Global",*FULL_HOSTS)
    categories=(*RESPONSES,"Monitor","Sleep","Other")
    categories=(*RESPONSES,"Monitor")
    max_rate=max(n for (t,pol,s),c in counts.items() if s=="executed" for n in c.values())/970
    for i,task in enumerate(REDS.values()):
        for j,policy in enumerate(sources):
            ax=axs[i,j]
            m=np.array([[100*counts[task,policy,"executed"][h,r]/97000 for r in categories] for h in hosts])
            im=ax.imshow(m,cmap="Blues",vmin=0,vmax=max_rate,aspect="auto")
            for y,x in np.ndindex(m.shape):
                if m[y,x]>=.1:
                    ax.text(x,y,f"{m[y,x]:.1f}",ha="center",va="center",fontsize=7,
                            color="white" if m[y,x]>.55*max_rate else "#14283A")
            ax.set_title(f"{task}  |  {policy}",fontsize=10)
            ax.set_xticks(range(len(categories)),categories,rotation=32,ha="right")
            ax.set_yticks(range(len(hosts)),hosts)
    fig.colorbar(im,ax=axs,fraction=.025,label="Share of post-opening decisions (%)")
    fig.suptitle("Every host and response",x=.02,ha="left",fontsize=16,fontweight="bold")
    save(fig,figures,"every-host-response")


def complexity_plot(summaries,figures):
    names=["bline-v14","final-bline","meander-v9","final-meander"]
    display=["B-line v14","B-line final","Meander v9","Meander final"]
    x=np.arange(len(names))
    fig,axs=plt.subplots(1,2,figsize=(10.6,4.5),layout="constrained")
    for i,key in enumerate(("stored","kept","structural_live")):
        axs[0].bar(x+(i-1)*.23,[summaries[n]["program_counts"][key] for n in names],width=.22,
                   label={"stored":"Original","kept":"Pruned","structural_live":"Bid slice"}[key],
                   color=(BLUE,ORANGE,GREEN)[i])
    axs[0].set_ylabel("Stored instructions")
    for i,key in enumerate(("instructions_original","instructions_pruned")):
        values=[next(iter(summaries[n]["runtime_per_decision"].values()),{}).get(key,0) for n in names]
        bars=axs[1].bar(x+(i-.5)*.27,values,width=.26,label=("Original","Pruned")[i],color=(BLUE,ORANGE)[i])
        axs[1].bar_label(bars,fmt="%.0f",padding=3,fontsize=7)
    axs[1].set_ylabel("Instructions per ranked query")
    for ax in axs:
        ax.legend(frameon=False)
        ax.set_xticks(x,display,rotation=22,ha="right")
        ax.grid(axis="y",alpha=.13)
        ax.set_axisbelow(True)
    fig.suptitle("Stored and active complexity",x=.015,ha="left",fontsize=16,weight="bold")
    save(fig,figures,"stored-and-active-complexity")


def activity_profiles(root,figures):
    fig,axs=plt.subplots(1,2,figsize=(11.2,4.9),layout="constrained")
    for ax,name,title in zip(axs,("final-bline","final-meander"),("B-line graph","Meander graph")):
        rows=list(csv_read(root/"tpg-visualization"/name/"team-activation.csv",","))
        candidates=sorted(rows,key=lambda r:(-int(r["selected"]),r["team"]))[:7]
        pos=np.arange(len(candidates))
        exposure=max(1,int(candidates[0]["selected"]))
        for i,key in enumerate(("top1","selected","delivered")):
            values=[100*int(r[key])/exposure for r in candidates]
            ax.barh(pos+(i-1)*.23,values,height=.22,color=(BLUE,ORANGE,GREEN)[i],label=key.title())
        ax.set_yticks(pos,[r["team"] for r in candidates])
        ax.invert_yaxis()
        ax.set(xlim=(0,105),xlabel="Share of archived post-opening decisions (%)",title=title)
        ax.legend(frameon=False,fontsize=8)
    fig.suptitle("Team decision participation",x=.015,ha="left",fontsize=16,fontweight="bold")
    save(fig,figures,"team-activity-profiles")


def scores(root,figures):
    evidence=root/"evidence"
    ref=read(evidence/"frozen-root153/official-results.json")
    fix=read(evidence/"graph-restore/root153-score/results.json")
    ppo=read(evidence/"cardiff-reference-results.json")
    old=read(evidence/"previous-controller-validation.json")["winner"]["expected_total"]
    horizons=(30,50,100)
    table=[]
    for red,task in REDS.items():
        older="bline-v14" if task=="B-line" else "meander-v9"
        old_rows=list(csv_read(evidence/f"{older}-root153-returns.tsv"))
        historic_full = {}
        if older=="meander-v9":
            text=(evidence/"meander-v9-historical-full-validation.log").read_text()
            for h,value,n in re.findall(r'meander-(\d+): mean=([^ ]+) std=[^ ]+ episodes=(\d+)',text):
                historic_full[int(h)]=(float(value.lower().replace("d","e")),int(n))
            assert set(historic_full)==set(horizons)
        for h in horizons:
            values=[float(x["tpg_return"].lower().replace("d","e"))
                    for x in old_rows if int(x["horizon"])==h]
            if h in historic_full:
                value,n=historic_full[h]
                table.append(dict(task=task,checkpoint=older,horizon=h,mean=value,episodes=n,
                                  protocol="historical standalone full; seed protocol differs"))
            elif values:
                table.append(dict(task=task,checkpoint=older,horizon=h,mean=mean(values),
                                  episodes=len(values),protocol="historical explicit episode seeds"))
            for name,result in (("BES final",ref),("BES Restore graph",fix),("Cardiff 90000",ppo)):
                cell=result["cells"][f"{h}-{red}"]
                table.append(dict(task=task,checkpoint=name,horizon=h,mean=cell["mean"],
                                  episodes=cell["episodes"],protocol="official continuous root 153"))
    csv_write(root/"checkpoint-capability.csv",table,["task","checkpoint","horizon","mean","episodes","protocol"])
    fig,axs=plt.subplots(1,2,figsize=(9.5,4.2),layout="constrained")
    for ax,task in zip(axs,REDS.values()):
        lines=[("bline-v14" if task=="B-line" else "meander-v9","#707984","--","Historical expert"),
               ("BES final",BLUE,"-","BES final"),("BES Restore graph",PURPLE,":","BES Restore graph"),
               ("Cardiff 90000",ORANGE,"-.","Cardiff reference")]
        for name,color,style,label in lines:
            selected=[r for r in table if r["task"]==task and r["checkpoint"]==name]
            ax.plot([r["horizon"] for r in selected],[r["mean"] for r in selected],
                    color=color,ls=style,marker="o",markersize=3,label=label)
        ax.set(title=task,xticks=horizons,xlabel="Decision horizon (steps)",ylabel="Mean reward")
        ax.grid(alpha=.2)
    handles,labels=axs[1].get_legend_handles_labels()
    fig.legend(handles,labels,loc="outside lower center",frameon=False,ncol=4,fontsize=8)
    fig.suptitle("Where checkpoints differ",x=.015,ha="left",fontsize=16,weight="bold")
    save(fig,figures,"checkpoint-task-capabilities")

    fig,ax=plt.subplots(figsize=(8,3.7),layout="constrained")
    values=[old,ref["total"],fix["total"]]
    ax.plot(range(len(values)),values,marker="o",color=BLUE)
    ax.axhline(ppo["total"],ls="--",color=ORANGE,label="Cardiff 90000 reference")
    for i,v in enumerate(values):
        ax.annotate(f"{v:.4f}",(i,v),xytext=(0,8),textcoords="offset points",ha="center")
    ax.set_xticks(range(len(values)),["Earlier Controller","Final release","Restore graph"])
    ax.set(ylabel="Official root 153 total",ylim=(min(ppo["total"]-.14,min(values)-.2),max(values)+.22))
    ax.legend(frameon=False,loc="lower right")
    ax.grid(axis="y",alpha=.2)
    ax.set_title("Pure-graph milestones on root 153")
    save(fig,figures,"pure-graph-milestones")

    roots=read(evidence/"graph-restore/results.json")["by_root"]
    axes=["Mean","CVaR 10%","Worst episode","Op_Server0\navailability","Persistent loss\n(episodes)"]
    floors=(-25.0,-45.0,-250.0,-250.0,-6.0)
    radar={}
    for key in ("native","graph"):
        series=[r[key] for r in roots.values()]
        radar[key]=[mean(v["cell100"]["mean"] for v in series),
                    mean(v["cell100"]["cvar10"] for v in series),
                    min(v["cell100"]["worst"] for v in series),
                    sum(v["op_impact"].get("100/availability",0) for v in series),
                    -sum(v["op_impact"].get("100/episodes_with_persistent_loss",0) for v in series)]
    dump(root/"checkpoint-radar-data.json",{"axes":axes,"floors":floors,"ideal":[0]*5,
                                           "matched_seed_roots":sorted(roots),"raw_values":radar})
    fig,ax=plt.subplots(figsize=(7.2,5.7),subplot_kw={"projection":"polar"},layout="constrained")
    theta=np.linspace(0,2*np.pi,len(axes),endpoint=False)
    for label,color,name in (("native",BLUE,"Final original graph"),("graph",PURPLE,"Pure Restore graph")):
        normalized=[max(0,min(1,1-v/floor)) for v,floor in zip(radar[label],floors)]
        ax.plot(np.r_[theta,theta[0]],np.r_[normalized,normalized[0]],color=color,label=name,linewidth=2)
        ax.fill(np.r_[theta,theta[0]],np.r_[normalized,normalized[0]],color=color,alpha=.13)
    ax.set_theta_zero_location("N")
    ax.set_theta_direction(-1)
    ax.set_xticks(theta,axes)
    ax.set_ylim(0,1)
    ax.set_yticks([.25,.5,.75,1],[".25",".50",".75","1"])
    ax.legend(loc="upper center",bbox_to_anchor=(.51,-.08),frameon=False,ncol=2)
    fig.suptitle("Meander checkpoint capability profile\n100-step, six matched evaluation roots",
                 fontsize=15,weight="bold")
    save(fig,figures,"checkpoint-capability-radar")
    return ref,fix,ppo


def draw_overlap(overlap,folder):
    stage=overlap["selected"]
    sets=stage["sets"]
    if not sets:
        return
    labels=list(sets)
    regions=stage["exclusive_regions"]
    fig,ax=plt.subplots(figsize=(5.4,4.1),layout="constrained")
    if len(labels)==1:
        ax.add_patch(Circle((0,0),1,color={"B-line":BLUE,"Meander":ORANGE}.get(labels[0],BLUE),alpha=.23))
        ax.text(0,0,str(len(sets[labels[0]])),ha="center",va="center",fontsize=17,weight="bold")
        ax.text(0,1.12,labels[0],ha="center",weight="bold")
    elif len(labels)==2:
        for x,label,color in zip((-.55,.55),labels,(BLUE,ORANGE)):
            ax.add_patch(Circle((x,0),1,color=color,alpha=.29))
            ax.text(x*1.9,1.13,label,ha="center",weight="bold")
        for x,key in zip((-1,0,1),(labels[0]," + ".join(labels),labels[1])):
            ax.text(x,0,str(regions[key]),ha="center",va="center",weight="bold")
    elif len(labels)==3:
        centers=((-0.55,-0.22),(0.55,-0.22),(0,0.62))
        for (x,y),label,color in zip(centers,labels,(BLUE,ORANGE,GREEN)):
            ax.add_patch(Circle((x,y),.92,color=color,alpha=.29))
            ax.text(x*2.08,y*2.58,label,ha="center",va="center",weight="bold")
        coords=((-1,-.36),(1,-.36),(0,1.1),(0,-.55),(-.45,.45),(.45,.45),(0,.04))
        order=(labels[0],labels[1],labels[2]," + ".join(labels[:2]),
               f"{labels[0]} + {labels[2]}",f"{labels[1]} + {labels[2]}"," + ".join(labels))
        for (x,y),label in zip(coords,order):
            ax.text(x,y,str(regions[label]),ha="center",va="center",weight="bold")
    else:
        items=sorted(((k,v) for k,v in regions.items() if v),key=lambda kv:-kv[1])
        pos=np.arange(len(items))
        ax.bar(pos,[v for _,v in items],color=BLUE)
        for i,label in enumerate(labels):
            ax.scatter(pos,np.full(len(pos),-i-1),
                       c=[BLUE if label in k.split(" + ") else "#D2DAE3" for k,_ in items],s=25)
        ax.set_yticks([-i-1 for i in range(len(labels))],labels)
        ax.set_xticks([])
        save(fig,folder,"task-overlap-upset")
        return
    ax.set(xlim=(-1.65,1.65),ylim=(-1.35,1.75),aspect="equal")
    ax.axis("off")
    ax.set_title("Team membership by task",fontsize=15)
    subtitle="Root used by every task" if stage["root_in_every_task"] else "Root coverage differs by task"
    ax.text(0,-1.17,subtitle,ha="center",fontsize=9,color="#4D5B6B")
    save(fig,folder,"task-overlap-venn")


def host_capability(root,figures):
    roots=read(root/"evidence/graph-restore/results.json")["by_root"]
    scores={}
    for mode in ("native","graph"):
        counts=Counter()
        for arms in roots.values():
            for cell,value in arms[mode]["host_loss"].items():
                horizon,host=cell.split("/",1)
                if horizon=="100":
                    counts[host]+=value
        scores[mode]=counts
    hosts=sorted(set(scores["native"])|set(scores["graph"]))
    delta={h:(scores["graph"][h]-scores["native"][h])/6000 for h in hosts}
    csv_write(root/"checkpoint-host-loss.csv",
              [dict(host=h,native=scores["native"][h]/6000,restore_graph=scores["graph"][h]/6000,
                    delta=delta[h]) for h in hosts],
              ["host","native","restore_graph","delta"])
    fig,ax=plt.subplots(figsize=(8.6,4.4),layout="constrained")
    ordered=sorted(hosts,key=delta.get)
    ax.barh(ordered,[delta[h] for h in ordered],color=[BLUE if delta[h]>=0 else ORANGE for h in ordered])
    ax.axvline(0,color="#536273",linewidth=.75)
    ax.set_xlabel("Change in mean host reward per episode (positive favors Restore graph)")
    ax.set_title("Host contributions to the Meander capability difference")
    ax.grid(axis="x",alpha=.2)
    save(fig,figures,"checkpoint-host-loss")


def checkpoint_report(p,summary):
    overlap=read(p/"task-overlap.json")
    graph=read(p/"graph-structure.json")
    teams=list(csv_read(p/"team-activation.csv",","))
    counts=summary["program_counts"]
    seen=set().union(*(set(s) for s in overlap["selected"]["sets"].values()))
    task_selected={t:len(s) for t,s in overlap["selected"]["sets"].items()}
    lines=[f"# {p.name}","",f"- Source: {summary['checkpoint']}",
           f"- Original SHA-256: {summary['original_sha256']}",f"- Pruned SHA-256: {summary['pruned_sha256']}",
           f"- Root: {summary['root']}",
           f"- Structure: {summary['teams']} Teams, {summary['learners']} Learners, {summary['atomic_terminals']} "
           f"atomic termini, {summary['edges']} edges. Maximum graph depth: "
           f"{summary['max_graph_depth'] if summary['max_graph_depth'] is not None else 'cyclic; global longest path not estimated'}.",
           f"- Selected Teams: {len(seen)} observed; per task {task_selected}.",
           f"- Maximum observed candidate path: {summary['max_observed_path_depth']}.",
           f"- Instructions: {counts['stored']} stored, {counts['structural_live']} in bid slice, {counts['kept']} after conservative pruning.",
           f"- {summary['verified_unique_contexts']} distinct contexts checked for identical original and pruned bids, "
           "evaluated teams, rankings, and candidate path identities.",
           f"- Task episode counts: {summary['episodes']}.",
           f"- Decisions by task and cohort: {summary['coverage_decisions']}.",
           f"- Trace accounting: {summary['trace_accounting']}.","",
           "Selected includes Team and Learner paths that emit Top-8 candidates. Evaluated denotes bid execution. "
           "Delivered requires an identified candidate in the Controller result. Classifier terminals are route labels.",""]
    if teams:
        lines += ["## Most visited Teams",""]
        for task in summary["decisions"]:
            ordered=sorted((r for r in teams if r["task"]==task),key=lambda r:-int(r["selected"]))[:5]
            lines += [f"- {task}: "+", ".join(f"{r['team']} ({r['selected']})" for r in ordered)]
        lines += ["",f"Unobserved Teams: {len(set(graph['teams'])-seen)}. Exact IDs are in the graph JSON and activation CSV.",""]
    else:
        lines += ["No matching observation-level trace. Activation is unknown.",""]
    lines += ["## Archive protocol",""]
    for s in summary["sources"]:
        lines.append(f"- {s['task']}, {s.get('cohort','continuous archive')}, horizons {s.get('horizons','as recorded')}. "
                     f"{s['path']} ({s.get('protocol','recorded trace')}; SHA-256 {s['source_sha256']}).")
    (p/"REPORT.md").write_text("\n".join(lines)+"\n",encoding="utf-8")


def finish(root):
    index=read(root/"archive-index.json")
    sub=root/"tpg-visualization"
    figs=root/"figures"
    figs.mkdir(exist_ok=True)
    summaries={name:read(sub/name/"summary.json") for name in index["checkpoints"]}
    action_plots(root,index,figs)
    dump(root/"evidence/action-archive-sha256.json",{name:sha(root/"evidence"/name)
           for name in ("final-root153-actions.tsv","cardiff-root153-actions.tsv")})
    complexity_plot(summaries,figs)
    activity_profiles(root,figs)
    ref,fix,ppo=scores(root,figs)
    host_capability(root,figs)
    for name,summary in summaries.items():
        checkpoint_report(sub/name,summary)
        draw_overlap(read(sub/name/"task-overlap.json"),sub/name)
    stability=[]
    for name,s in summaries.items():
        for entity,field in (("team","coverage_by_cohort"),("learner","learner_coverage_by_cohort")):
            for stage in ("evaluated","selected","top1","delivered"):
                cohorts={k:set(v) for k,v in s.get(field,{}).items() if k.endswith("/"+stage)}
                anchor=[v for k,v in cohorts.items() if k.split("/")[1] in ("153","153-explicit")]
                other=[v for k,v in cohorts.items() if k.split("/")[1] not in ("153","153-explicit")]
                if anchor and other:
                    base,comparison=set.union(*anchor),set.union(*other)
                    stability.append(dict(checkpoint=name,entity=entity,event=stage,root153=len(base),
                                          other_cohorts=len(comparison),other_only=len(comparison-base)))
    csv_write(root/"cross-seed-activation.csv",stability,
              ["checkpoint","entity","event","root153","other_cohorts","other_only"])
    lines=["# BES final policy analysis","",
           f"Official continuous root 153: final BES **{ref['total']:.4f}**, pure Restore graph "
           f"**{fix['total']:.4f}**, Cardiff 90000 reference **{ppo['total']:.4f}**.","",
           "The final BES lead over this Cardiff reference is 0.8800 at root 153. B-line contributes +0.9896, "
           "Meander contributes -0.1096, and Sleep contributes 0. This is the matched root 153 protocol.","",
           "Official scores come from archived closed-loop runs. Original and pruned copies were checked on "
           "recorded observations. This analysis added **0** official environment transitions.","",
           "## Pruning and complexity",""]
    for name in summaries:
        q=summaries[name]
        n=q["program_counts"]
        per_step=next(iter(q["runtime_per_decision"].values()),None)
        lines.append(f"- {name}: {n['stored']:,} instructions to {n['kept']:,} after pruning "
                     f"({(n['stored']-n['kept'])/n['stored']:.1%}); {q['teams']:,} Teams, {q['learners']:,} Learners; "
                     f"{sum(q['decisions'].values()):,} archive decisions with matching rankings."
                     + (f" Ranked-query instruction count {per_step['instructions_original']:.2f} to "
                        f"{per_step['instructions_pruned']:.2f} on that archive." if per_step else ""))
    lines += ["","## Evidence scope","",
              "- The two pure-graph root 153 runs have identical returns for all 9,000 episodes. "
              "The corresponding official score does not establish a new score for a pruned bundle.",
              "- The official root 153 archive has actions and rewards. It does not have obs62, decoy masks, or candidate paths. "
              "Final B-line activation uses the separately labelled native expert archives including explicit root 153 seeds. "
              "Final Meander uses ten independent single-cell 100-step roots.",
              "- Historical checkpoint curves are descriptive. Their explicit episode seed protocol and Controller profiles differ.",
              "- The one-shot guard is confined to the evidence archive. Candidate comparisons use Controller and serialized TPG graphs.",
              "- Static instruction reduction is conservative. It preserves all Teams, atomic terminals and graph edges. "
              "Instructions that could trap and their needed operands are preserved.",
              "- For historical delivery, use the archived chosen rank when its recorded semantic action matches both the emitted "
              "candidate and the concrete action. Unattributed deliveries stay out of delivered-only paths.",
              "- The shared three-task opening classifier is the like-for-like Figure 5 demonstration. Its atomic terminals are route labels. "
              "The two separate expert checkpoints have distinct Team identities.",
              "- The host-protection radar uses observed host loss over six matched Meander roots. Scores are scaled per host with an "
              "explicit cap, and the raw rates are exported. The Decoy radar measures deployments, with differing historical B-line "
              "protocols labelled as such. It does not estimate the effect of a deployment.",
              "- The Semantic-36 response and targeting radars compare all four responses and nine learned hosts. "
              "Dashed lines show first proposals. Solid lines show actual Controller deliveries. Raw rates are "
              "exported per pair. Global Monitor and any other out-of-catalog actions have separate CSV counts.",
              "- Observation indexing counts OBS operands actually accessed during bid execution. Action association uses "
              "the union of bid-live features on verified delivered paths. An association is not a causal effect.",
              "- Root 153 action charts exclude three fixed opening actions per episode. They count the actual concrete actions.",
              "- See each checkpoint report for graph depth, active paths, task-region counts, and trace provenance.",
              "- The deployable derivative with all three original inputs pruned is in root153-final-pruned. "
              "Its checksum list and scheduler verify without simulator interaction.","",
              "## Reproduce","",
              "Run code/visualize_tpg.py with --checkpoint, --traces, --output and --code. Use the matching pinned "
              "BES source tree. Without --traces it produces a Full Graph and a pruned copy. Run code/figures.py "
              "--report <directory> with Matplotlib and NumPy. The archive index records the exact source paths and hashes. "
              "After exporting observation-sources for the two expert checkpoints, run code/expert_figures.py --report "
              "<directory> and code/semantic_radars.py --report <directory>, then code/figures.py to regenerate the landing page.",""]
    (root/"REPORT.md").write_text("\n".join(lines),encoding="utf-8")
    panels=(("tpg-wins-vs-execution","TPG winning proposals and actual execution"),
            ("tpg-vs-ppo-response-pies","TPG / PPO response comparison"),
            ("host-response-decomposition","Host-response decomposition"),
            ("every-host-response","Every host and response"),
            ("stored-and-active-complexity","Stored and active complexity"),
            ("pure-graph-milestones","Pure-graph milestones"),
            ("checkpoint-task-capabilities","Checkpoint task capabilities"),
            ("checkpoint-capability-radar","Checkpoint capability radar"),
            ("checkpoint-host-loss","Host contributions to capability differences"),
            ("team-activity-profiles","Team decision participation"))
    cards="\n".join(f'<section><h2>{title}</h2><a href="figures/{name}.svg">'
                    f'<img loading="lazy" src="figures/{name}.png" alt="{title}"></a>'
                    f'<p><a href="figures/{name}.pdf">PDF</a></p></section>' for name,title in panels)
    graph_list=[]
    for name in summaries:
        folder=f"tpg-visualization/{name}"
        links=[("policy-graph.svg","Selected candidate paths"),("top1-graph.svg","Top-1"),
               ("delivered-graph.svg","Delivered"),("full-graph.svg","Full graph"),
               ("REPORT.md","Data and methods")]
        graph_list.append(f'<li><strong>{escape(name)}</strong> '+" &middot; ".join(
            f'<a href="{folder}/{file}">{label}</a>' for file,label in links if (root/folder/file).exists())+"</li>")
    expert_cards=[]
    for name,title in (("final-bline","B-line"),("final-meander","Meander")):
        directory=f"tpg-visualization/{name}"
        graph_file=root/directory/"expert-paper-paths.json"
        if not graph_file.is_file():
            continue
        path_info=read(graph_file)
        expert_cards.append(f'<section><h2>{title} expert</h2>'
                            f'<p>Root Team <code>{path_info["root"]}</code>. One verified frequent delivered path per response family. '
                            'Circles are Teams, braces are learners, and rectangles are semantic actions.</p>'
                            '<div class="expert-grid">'
                            f'<a href="{directory}/expert-policy-graph.svg">'
                            f'<img src="{directory}/expert-policy-graph.png" alt="{title} true expert graph"></a>'
                            f'<a href="{directory}/expert-path-overlap.svg">'
                            f'<img src="{directory}/expert-path-overlap.png" alt="{title} response paths overlap"></a></div>'
                            f'<p><a href="{directory}/expert-policy-graph.pdf">Expert graph PDF</a> &middot; '
                            f'<a href="{directory}/expert-paper-paths.json">Exact paths and counts</a> &middot; '
                            f'<a href="{directory}/policy-graph.svg">All candidate paths</a> &middot; '
                            f'<a href="{directory}/delivered-graph.svg">All delivered paths</a> &middot; '
                            f'<a href="{directory}/full-graph.svg">Full graph</a></p></section>')
    extras=[]
    for name,title,caption in (
        ("bline-semantic-response-radar","B-line response mix",
         "All four semantic responses. Dashed lines are Top-1 proposals and solid lines are Controller deliveries."),
        ("meander-semantic-response-radar","Meander response mix",
         "All four semantic responses, aggregated over six matched roots."),
        ("bline-semantic-host-response-radar","B-line | host targeting by response",
         "Each panel compares the same nine Semantic-36 hosts. The two versions use different root 153 episode protocols."),
        ("meander-semantic-host-response-radar","Meander | host targeting by response",
         "Each panel compares the same nine Semantic-36 hosts. All rates use post-opening decisions as the denominator."),
        ("semantic-36-checkpoint-differences","Which of the 36 actions changed most?",
         "Exact percentage-point changes in proposal and delivery shares. Color scales are separate by task."),
        ("checkpoint-host-protection-radar","Checkpoint capability by host",
         "Outward means lower measured host loss. Axes are scaled separately; raw values are linked below."),
        ("checkpoint-decoy-deployment-radar","Decoy deployment across checkpoints",
         "Outward means more deployments on that host. The B-line cohorts use different evaluation protocols; Meander roots are matched."),
        ("b-line-observation-indexing","B-line observation indexing",
         "Original and pruned program access, with feature pairs and action associations from verified delivered paths."),
        ("meander-observation-indexing","Meander observation indexing",
         "Original and pruned program access, with feature pairs and action associations from verified delivered paths."),
    ):
        if (figs/f"{name}.png").exists():
            extras.append(f'<section><h2>{title}</h2><p>{caption}</p><a href="figures/{name}.svg">'
                          f'<img loading="lazy" src="figures/{name}.png" alt="{title}"></a>'
                          f'<p><a href="figures/{name}.pdf">PDF</a></p></section>')
    (root/"index.html").write_text("""<!doctype html><meta charset="utf-8">
<meta name="viewport" content="width=device-width"><title>BES final policy analysis</title><style>
body{max-width:1050px;margin:3rem auto;padding:0 24px;font:16px/1.65 system-ui;color:#162336;background:white}
h1{font-size:2.5rem;line-height:1.08}h2{margin:2.5rem 0 .7rem}p{max-width:80ch}a{color:#23578f}
img{max-width:100%;height:auto}section{margin:1.2rem 0;border-top:1px solid #d9e2eb}li{margin:.55rem 0}
.expert-grid{display:grid;grid-template-columns:minmax(0,2fr) minmax(0,1fr);gap:20px;align-items:center}
@media(max-width:720px){.expert-grid{grid-template-columns:1fr}}
</style><h1>BES final policy analysis</h1>
<p>Official root 153 result <strong>&minus;56.6674</strong>. This archive documents pure-graph checkpoints,
Controller delivery, conservative instruction pruning, and measured task activation.</p>
<p><a href="REPORT.md">Research report</a> &middot; <a href="archive-index.json">Evidence index</a> &middot;
<a href="root153-final-pruned/README.md">Pruned checkpoint bundle</a> &middot;
<a href="cross-seed-activation.csv">Cross-seed activation</a> &middot; <a href="checkpoint-capability.csv">Capability data</a></p>
"""+"".join(expert_cards)+"".join(extras)+"""
<section><h2>Download study data</h2><ul>
<li><a href="semantic-36-checkpoint-radar.csv">All Semantic-36 counts and rates</a> &middot;
<a href="semantic-36-checkpoint-radar-provenance.json">Trace provenance</a></li>
<li><a href="checkpoint-host-radar-data.csv">Host protection radar data</a></li>
<li><a href="checkpoint-decoy-radar-data.csv">Decoy deployment radar data</a></li>
<li>B-line <a href="tpg-visualization/final-bline/observation-index-frequency.csv">Index counts</a> &middot;
<a href="tpg-visualization/final-bline/observation-combinations-actions.csv">Feature sets per action</a> &middot;
<a href="tpg-visualization/final-bline/observation-pair-actions.csv">Feature pairs per action</a> &middot;
<a href="tpg-visualization/final-bline/observation-value-pair-actions.csv">Observed value pairs</a></li>
<li>Meander <a href="tpg-visualization/final-meander/observation-index-frequency.csv">Index counts</a> &middot;
<a href="tpg-visualization/final-meander/observation-combinations-actions.csv">Feature sets per action</a> &middot;
<a href="tpg-visualization/final-meander/observation-pair-actions.csv">Feature pairs per action</a> &middot;
<a href="tpg-visualization/final-meander/observation-value-pair-actions.csv">Observed value pairs</a></li>
</ul></section>
<details><summary>Checkpoint graph archive and opening classifier</summary><ul>"""+"".join(graph_list)+
"""</ul></details>"""+cards,encoding="utf-8")


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report",type=Path,required=True)
    finish(parser.parse_args().report)

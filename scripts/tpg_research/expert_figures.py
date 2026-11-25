#!/usr/bin/env python3
"""Figure 5-style expert panels and observation access from verified archived paths."""
from collections import Counter, defaultdict
from itertools import combinations
from pathlib import Path
from statistics import mean
import argparse
import json
import re
import shutil
import subprocess

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

from figures import BLUE, ORANGE, GREEN, PURPLE, REDS, FULL_HOSTS, executed, read, save, semantic
from visualize_tpg import HOSTS, concrete_pair, contexts, csv_read, csv_write, dump

FEATURES = [f"{h}.{field}" for h in FULL_HOSTS for field in
            ("activity[0]","activity[1]","compromised[0]","compromised[1]")]
FEATURES += [f"{host}.scan" for host in HOSTS[1:]]
RESPONSE_ORDER = ("Analyse","Remove","Restore","Decoy","Monitor")
COLORS = dict(zip(RESPONSE_ORDER,(BLUE,ORANGE,"#CC6677",GREEN,"#808895")))
CONTEXT = re.compile(r'^\((\d+) "([012]{62})" (\d+|nil) ([^ ]+) ([^ )]+)\)$')


def feature(i):
    return f"{i:02d} {FEATURES[i]}"


def indices(value):
    return tuple(map(int,value.split(","))) if value else ()


def archived_rank(row,actual,rank,pair):
    native=concrete_pair(actual) if actual else None
    if rank and rank.isdigit():
        i=int(rank)
        if i<len(row["ranking"]) and row["ranking"][i]==pair==native:
            return i
    elif actual==row["concrete"] and row["resolution"]=="candidate":
        i=int(row["rank"])
        if native==row["ranking"][i]:
            return i
    return None


def load_contexts(folder):
    graph=read(folder/"graph-structure.json")
    summary=read(folder/"summary.json")
    keys={}
    with (folder/"contexts.sexp").open() as inp:
        for line in inp:
            i,obs,mask,profile,mode=CONTEXT.fullmatch(line.strip()).groups()
            keys[obs,int(mask) if mask!="nil" else None,profile,mode]=int(i)
    paths={}
    for row in csv_read(folder/"verified-context-paths.tsv"):
        row["ranking"]=row["ranking"].split(",")
        row["paths"]=[tuple(path.split(",")) for path in row["paths"].split(";")]
        row["evaluated_teams"]=row["evaluated_teams"].split(",")
        paths[int(row["id"])]=row
    sources={r["learner"]:tuple(indices(r[k]) for k in
                                 ("original_reads","retained_reads","bid_live_reads"))
             for r in csv_read(folder/"program-observation-sources.tsv")}
    assert sources.keys()==graph["learners"].keys()
    return graph,summary,keys,paths,sources


def observation_audit(folder):
    graph,summary,keys,by_id,sources=load_contexts(folder)
    queries=Counter()
    deliveries=Counter()
    episodes=set()
    for task,cohort,episode,ctx,concrete,ranking,rank,pair in contexts(summary["sources"]):
        i=keys[ctx]
        row=by_id[i]
        if ranking and ",".join(row["ranking"])!=ranking:
            continue
        queries[i]+=1
        episodes.add((task,cohort,episode))
        selected=archived_rank(row,concrete,rank,pair)
        if selected is not None:
            deliveries[i,selected,int(concrete)]+=1
    assert sum(queries.values())==sum(summary["decisions"].values())
    by_feature=defaultdict(Counter)
    terminal_paths=Counter()
    action_feature=Counter()
    combinations_exact=Counter()
    paths_with_reads={}
    def live_for(path):
        if path not in paths_with_reads:
            paths_with_reads[path]=tuple(sorted(set(x for learner in path for x in sources[learner][2])))
        return paths_with_reads[path]
    for i,n in queries.items():
        row=by_id[i]
        learners=[l for t in row["evaluated_teams"] for l in graph["teams"][t]]
        for batch,k in enumerate(("original_operand_reads","retained_operand_reads","bid_live_operand_reads")):
            counter=Counter(x for learner in learners for x in sources[learner][batch])
            for x,count in counter.items():
                by_feature[k][x]+=n*count
                by_feature[k+"_queries"][x]+=n
        for x in live_for(row["paths"][0]):
            by_feature["winning_path_queries"][x]+=n
    observation_for={i:k[0] for k,i in keys.items()}
    observed_values=Counter()
    for (i,rank,concrete),n in deliveries.items():
        path=by_id[i]["paths"][rank]
        terminal_paths[path,concrete]+=n
        _,response=executed(concrete)
        observed_values[live_for(path),observation_for[i],response]+=n
    for (path,concrete),n in terminal_paths.items():
        features=live_for(path)
        h,a=executed(concrete)
        for x in features:
            by_feature["delivered_path_queries"][x]+=n
            action_feature[h,a,x]+=n
        combinations_exact[h,a,features]+=n
    n=sum(queries.values())
    m=sum(deliveries.values())
    columns=list(by_feature.keys())
    rows=[{"index":i,"feature":FEATURES[i],**{k:by_feature[k][i] for k in columns}}
          for i in range(62)]
    csv_write(folder/"observation-index-frequency.csv",rows,["index","feature",*columns])
    csv_write(folder/"observation-action-association.csv",
              [dict(host=h,response=a,index=i,feature=FEATURES[i],decisions=v)
               for (h,a,i),v in sorted(action_feature.items())],
              ["host","response","index","feature","decisions"])
    csv_write(folder/"observation-combinations-actions.csv",
              [dict(host=h,response=a,feature_indices=" ".join(map(str,features)),
                    features=" + ".join(FEATURES[i] for i in features),decisions=v)
               for (h,a,features),v in combinations_exact.most_common()],
              ["host","response","feature_indices","features","decisions"])
    action_total=Counter()
    pairs_by_action=Counter()
    for (h,a,features),v in combinations_exact.items():
        action_total[h,a]+=v
        for ix,jx in combinations(features,2):
            pairs_by_action[h,a,ix,jx]+=v
    value_pairs=Counter()
    for (feature_set,obs,response),weight in observed_values.items():
        for i,j in combinations(feature_set,2):
            value_pairs[response,i,int(obs[i]),j,int(obs[j])]+=weight
    csv_write(folder/"observation-value-pair-actions.csv",
              [dict(response=response,index_a=i,value_a=a,index_b=j,value_b=b,
                    feature_a=FEATURES[i],feature_b=FEATURES[j],decisions=n)
               for (response,i,a,j,b),n in value_pairs.most_common()],
              ["response","index_a","value_a","index_b","value_b","feature_a","feature_b","decisions"])
    csv_write(folder/"observation-pair-actions.csv",
              [dict(host=h,response=a,index_a=i,index_b=j,feature_a=FEATURES[i],feature_b=FEATURES[j],
                    decisions=v,share_within_action=v/action_total[h,a])
               for (h,a,i,j),v in pairs_by_action.most_common()],
              ["host","response","index_a","index_b","feature_a","feature_b","decisions","share_within_action"])
    dump(folder/"observation-audit-summary.json",
         {"decisions":n,"linked_deliveries":m,"episodes":len(episodes),
          "all_paths":len(terminal_paths),"root":graph["root"],
          "delivery_coverage":m/n,"feature_count":62,
          "meaning":"Direct OBS operands indexed by executed bid programs; association uses static live bid slices on verified paths."})
    return graph,summary,n,m,by_feature,terminal_paths,action_total,action_feature,value_pairs


def paper_graph(folder,task,graph,n,m,paths,dot):
    # Use exactly the most frequent verified path for each observed response.
    # The complete activated structure remains independently exported.
    counts=Counter()
    concrete_by_path=defaultdict(Counter)
    for (path,concrete),weight in paths.items():
        response=executed(concrete)[1]
        counts[response,path]+=weight
        concrete_by_path[response,path][concrete]+=weight
    chosen={}
    response_total=Counter()
    for (response,path),weight in counts.items():
        response_total[response]+=weight
        if response not in chosen or (weight,path)>(chosen[response][0],chosen[response][1]):
            chosen[response]=(weight,path)
    groups={response:chosen[response] for response in RESPONSE_ORDER if response in chosen}
    memberships=defaultdict(set)
    edges=set()
    for response,(weight,path) in groups.items():
        trail=[graph["root"]]
        for l in path:
            data=graph["learners"][l]
            assert data["team"]==trail[-1]
            trail.extend([l,data["target"] if data["kind"]=="team" else "action/"+l])
        assert trail[-1] in graph["actions"]
        for x in trail:
            memberships[x].add(response)
        edges.update(zip(trail,trail[1:]))
    assert edges<=set(map(tuple,graph["edges"]))
    regions=Counter(tuple(sorted(g)) for node,g in memberships.items() if node in graph["teams"])
    dump(folder/"expert-paper-paths.json",{
        "checkpoint_sha256":read(folder/"summary.json")["pruned_sha256"],"root":graph["root"],
        "display_rule":"Most frequent verified delivered candidate path within each recorded response family",
        "archive_decisions":n,"linked_deliveries":m,
        "displayed_paths":{r:{"count":w,"response_total":response_total[r],"learners":list(p),
                               "concrete_deliveries":concrete_by_path[r,p]} for r,(w,p) in groups.items()},
        "displayed_team_intersections":{" + ".join(g):v for g,v in regions.items()},
        "displayed_nodes":len(memberships),"displayed_edges":len(edges),
    })
    q=json.dumps
    output=folder/"expert-policy-graph.dot"
    with output.open("w",encoding="utf-8") as f:
        f.write('digraph expert { graph [rankdir=TB,bgcolor=white,pad=.21,'
                'fontsize=14,fontname="Arial",labelloc=t,nodesep=.32,ranksep=.13];'
                '\nnode [fontname="Arial",fontsize=10,style=filled];'
                '\nedge [color="#A1AAB4",penwidth=.7,arrowsize=.40];\n')
        f.write(f'label={q(task+" expert | "+graph["root"]+" | Verified response paths")};\n')
        for node,g in sorted(memberships.items()):
            fill=COLORS[next(iter(g))] if len(g)==1 else "#695684"
            tooltip=node+" | "+", ".join(sorted(g))
            if node==graph["root"]:
                attrs='shape=circle,peripheries=2,width=.43,label="Root",fillcolor="#232836",fontcolor=white'
            elif node in graph["teams"]:
                attrs=f'shape=circle,width=.17,height=.17,fixedsize=true,label="",fillcolor={q(fill)},color=white'
            elif node in graph["learners"]:
                attrs=f'shape=plaintext,label="{{ }}",fontcolor={q(fill)},style=solid,width=.14,height=.10'
            else:
                label=" / ".join(semantic(graph["actions"][node]))
                attrs=f'shape=box,style="rounded,filled",label={q(label)},fillcolor="#465465",fontcolor=white,margin=".06,.045"'
            f.write(f'{q(node)} [{attrs},tooltip={q(tooltip)}];\n')
        for a,b in sorted(edges):
            f.write(f"{q(a)} -> {q(b)};\n")
        f.write("}\\n")
    render_paper_graph(output,folder,dot)
    return len(memberships),len(edges)


def render_paper_graph(dotfile,folder,dot):
    for kind in ("svg","pdf","png"):
        with dotfile.open("rb") as source,(folder/f"expert-policy-graph.{kind}").open("wb") as target:
            subprocess.run([dot,"-Kneato","-Gstart=17","-Goverlap=prism","-Gsep=0.08",
                            "-Gmaxiter=1000","-Gsize=8.4,6.8","-Gdpi=140","-T"+kind],
                           stdin=source,stdout=target,check=True)

def membership_plot(folder,task):
    info=read(folder/"expert-paper-paths.json")
    groups=list(info["displayed_paths"])
    regions=sorted(info["displayed_team_intersections"].items(),
                   key=lambda row:(-len(row[0].split(" + ")),-row[1],row[0]))
    x=np.arange(len(regions))
    fig,(counts,marks)=plt.subplots(2,1,figsize=(6.8,3.4),sharex=True,
                                   gridspec_kw={"height_ratios":[2,1]},layout="constrained")
    bars=counts.bar(x,[n for _,n in regions],color=["#695684" if " + " in key else COLORS[key]
                                                  for key,n in regions],width=.55)
    counts.bar_label(bars,fontsize=9)
    counts.set_ylabel("Teams")
    counts.set_ylim(0,max(n for _,n in regions)*1.23)
    marks.set_yticks(range(len(groups)),groups)
    marks.set_xticks(x,[""]*len(x))
    marks.invert_yaxis()
    for j,(key,n) in enumerate(regions):
        subset=set(key.split(" + "))
        points=[i for i,r in enumerate(groups) if r in subset]
        if len(points)>1:
            marks.plot([j,j],[min(points),max(points)],color="#695684",linewidth=1)
        for i,r in enumerate(groups):
            marks.scatter(j,i,s=27,c=[COLORS[r] if r in subset else "#DFE4EB"],zorder=3)
    marks.set_xlabel("Exact membership in the displayed response paths")
    fig.suptitle(f"{task} expert  |  Team overlap",x=.02,ha="left",fontsize=14,weight="bold")
    save(fig,folder,"expert-path-overlap")


def observation_plot(figures,task,n,m,by_feature,action_total,action_feature,value_pairs):
    order=sorted(range(62),key=lambda i:(-by_feature["retained_operand_reads"][i],i))[:13]
    responses=[r for r in RESPONSE_ORDER if any(a==r for h,a in action_total)]
    denominators={a:sum(v for (h,r),v in action_total.items() if r==a) for a in responses}
    rates={i:[100*sum(v for (h,r,x),v in action_feature.items() if r==a and x==i)
                    /denominators[a] for a in responses] for i in range(62)}
    differential=sorted(rates,key=lambda i:(-np.ptp(rates[i]),-max(rates[i]),i))[:13]
    assoc=np.array([rates[i] for i in differential])
    pairs=defaultdict(Counter)
    for (response,i,a,j,b),v in value_pairs.items():
        pairs[i,a,j,b][response]+=v
    common=[(pair,[100*counts[a]/denominators[a] for a in responses])
            for pair,counts in pairs.items() if sum(counts.values())>=max(100,m*.003)]
    contrasting=sorted(common,key=lambda row:(-np.ptp(row[1]),-max(row[1]),row[0]))[:7]
    fig=plt.figure(figsize=(12.1,8.3),layout="constrained")
    grid=fig.add_gridspec(2,2,height_ratios=[2.3,1],width_ratios=[1.25,1])
    ax=fig.add_subplot(grid[0,0])
    y=np.arange(len(order))
    ax.barh(y-.18,[by_feature["original_operand_reads"][i]/n for i in order],height=.34,
            label="Original",color="#A8BDD1")
    ax.barh(y+.18,[by_feature["retained_operand_reads"][i]/n for i in order],height=.34,
            label="Pruned",color=BLUE)
    ax.set_yticks(y,[feature(i) for i in order])
    ax.invert_yaxis()
    ax.set_xlabel("Observation operand reads per ranked query")
    ax.set_title("A  Bid-program indexing")
    ax.legend(frameon=False,loc="upper center",bbox_to_anchor=(.5,-.13),ncol=2,fontsize=8)
    ax.grid(axis="x",alpha=.18)
    ax=fig.add_subplot(grid[0,1])
    im=ax.imshow(assoc,cmap="Blues",vmin=0,vmax=100,aspect="auto")
    ax.set_xticks(range(len(responses)),responses,rotation=25,ha="right")
    ax.set_yticks(range(len(differential)),[feature(i) for i in differential],fontsize=8)
    for yi,xi in np.ndindex(assoc.shape):
        v=assoc[yi,xi]
        if v>=.5:
            ax.text(xi,yi,f"{v:.0f}",ha="center",va="center",fontsize=7,
                    color="white" if v>56 else "#1B2736")
    fig.colorbar(im,ax=ax,fraction=.04,label="Delivered paths indexing the feature (%)")
    ax.set_title("B  Observation coverage by delivered response")
    ax=fig.add_subplot(grid[1,:])
    y=np.arange(len(contrasting))
    for j,response in enumerate(responses):
        ax.scatter([v[j] for _,v in contrasting],y+(.10*(j-(len(responses)-1)/2)),
                   s=27,label=response,color=COLORS[response])
    ax.set_yticks(y,[f"{feature(i)} = {a}  +  {feature(j)} = {b}"
                     for (i,a,j,b),_ in contrasting],fontsize=8)
    ax.invert_yaxis()
    ax.set_xlim(-3,103)
    ax.set_xlabel("Share of attributable decisions within each response (%)")
    ax.set_title("C  Co-observed values with the largest response differences")
    ax.grid(axis="x",alpha=.17)
    ax.legend(frameon=False,loc="upper center",bbox_to_anchor=(.5,-.23),ncol=len(responses),fontsize=8)
    fig.suptitle(f"{task} expert  |  Observation indexing and action association",
                 x=.011,ha="left",fontsize=16,weight="bold")
    save(fig,figures,task.lower()+"-observation-indexing")


def radar(ax,features,values,colors,scale,title):
    theta=np.linspace(0,2*np.pi,len(features),endpoint=False)
    for (label,series),color in zip(values.items(),colors):
        r=np.divide(series,scale,out=np.zeros(len(features)),where=np.asarray(scale)!=0)
        ax.plot(np.r_[theta,theta[0]],np.r_[r,r[0]],color=color,marker="o",markersize=3,label=label)
        ax.fill(np.r_[theta,theta[0]],np.r_[r,r[0]],color=color,alpha=.09)
    ax.set_theta_zero_location("N")
    ax.set_theta_direction(-1)
    ax.set_xticks(theta,features)
    ax.set_ylim(0,1.06)
    ax.set_yticks([.25,.5,.75,1],[".25",".50",".75","1"],fontsize=7)
    ax.tick_params(axis="x",pad=7)
    ax.set_title(title,pad=30,fontsize=10)
    ax.legend(loc="upper center",bbox_to_anchor=(.5,-.13),frameon=False,fontsize=8)


def host_radar(root,figures):
    raw=read(root/"evidence/graph-restore/results.json")["by_root"]
    arms={"Final Meander":"native","Pure Restore graph":"graph"}
    result={}
    for policy,arm in arms.items():
        counts=Counter()
        for outcomes in raw.values():
            for entry,loss in outcomes[arm]["host_loss"].items():
                h,host=entry.split("/",1)
                if h=="100":
                    counts[host]+=-loss/6000
        result[policy]=counts
    counts=Counter()
    for items in result.values():
        counts.update(items)
    hosts=[h for h,_ in counts.most_common(5)]
    if "Op_Server0" not in hosts:
        hosts.append("Op_Server0")
    cap=[2*max(.01,*(result[p][h] for p in result)) for h in hosts]
    index={p:[1-result[p][h]/v for h,v in zip(hosts,cap)] for p in result}
    csv_write(root/"checkpoint-host-radar-data.csv",
              [dict(checkpoint=p,host=h,mean_loss=result[p][h],axis_cap=v,protection_index=s)
               for p in result for h,v,s in zip(hosts,cap,index[p])],
              ["checkpoint","host","mean_loss","axis_cap","protection_index"])
    fig,ax=plt.subplots(figsize=(7.3,6.0),subplot_kw={"projection":"polar"},layout="constrained")
    radar(ax,hosts,index,[BLUE,PURPLE],np.ones(len(hosts)),"Six matched roots, Meander 100-step")
    fig.suptitle("Checkpoint capability  |  Host protection",x=.02,ha="left",fontsize=16,weight="bold")
    save(fig,figures,"checkpoint-host-protection-radar")


def decoy_profile(root,figures):
    raw=read(root/"evidence/graph-restore/results.json")["by_root"]
    complete=root/"evidence/final-root153-actions.tsv"
    historical=read(root/"archive-index.json")["checkpoints"]["bline-v14"]["traces"]
    past=next(s["path"] for s in read(Path(historical)) if "root-153/" in s["path"])
    final=defaultdict(lambda:Counter())
    previous=defaultdict(lambda:Counter())
    for row in csv_read(complete):
        if row["red"]=="B_lineAgent" and row["horizon"]=="100" and int(row["step"])>=3:
            final[row["episode"]][int(row["concrete"])]+=1
    for row in csv_read(past):
        if row["BEHAVIOR"]=="TPG" and row["HORIZON"]=="100" and int(row["STEP"])>=3:
            previous[row["EPISODE"]][int(row["EXECUTED_CONCRETE"])]+=1
    bline_counts={}
    for policy,episodes in (("B-line v14",previous),("Final B-line",final)):
        assert len(episodes)==1000
        counter=Counter()
        for batch in episodes.values():
            for action,n in batch.items():
                host,response=executed(action)
                if response=="Decoy":
                    counter[host]+=n/len(episodes)
        bline_counts[policy]=counter
    meander={}
    for policy,arm in (("Final Meander","native"),("Pure Restore graph","graph")):
        counter=Counter()
        for row in raw.values():
            for action,n in row[arm]["cell100"]["concrete_counts"].items():
                host,response=executed(action)
                if response=="Decoy":
                    counter[host]+=n/6000
        meander[policy]=counter
    fig,axs=plt.subplots(1,2,figsize=(11.5,5.25),subplot_kw={"projection":"polar"},layout="constrained")
    output=[]
    for axis,(title,counts) in zip(axs,(("B-line | differing root 153 protocols",bline_counts),
                                       ("Meander | six matched roots",meander))):
        exposure=Counter()
        for items in counts.values():
            exposure.update(items)
        selection=[h for h,_ in exposure.most_common(6)]
        cap=[max(.25,*(item[h] for item in counts.values())) for h in selection]
        vals={p:[items[h] for h in selection] for p,items in counts.items()}
        radar(axis,selection,vals,[BLUE,PURPLE],cap,title)
        radii=dict(zip(selection,cap))
        output.extend(dict(checkpoint=p,host=h,deployments_per_episode=counts[p][h],
                           displayed=h in selection,axis_cap=radii.get(h,""))
                      for p in counts for h in FULL_HOSTS)
    csv_write(root/"checkpoint-decoy-radar-data.csv",output,
              ["checkpoint","host","deployments_per_episode","displayed","axis_cap"])
    fig.suptitle("Checkpoint behavior  |  Decoy deployment by host",
                 x=.02,ha="left",fontsize=16,weight="bold")
    save(fig,figures,"checkpoint-decoy-deployment-radar")


def main(root):
    figs=root/"figures"
    dot=shutil.which("dot") or shutil.which("dot.exe")
    if not dot:
        raise RuntimeError("Graphviz is required")
    for nm,task in (("final-bline","B-line"),("final-meander","Meander")):
        folder=root/"tpg-visualization"/nm
        g,s,n,m,feature,paths,counts,association,pairs=observation_audit(folder)
        vertices,edges=paper_graph(folder,task,g,n,m,paths,dot)
        membership_plot(folder,task)
        observation_plot(figs,task,n,m,feature,counts,association,pairs)
        print(f"EXPERT_PASS {task} root={g['root']} decisions={n} delivered={m} nodes={vertices} edges={edges}",flush=True)
    host_radar(root,figs)
    decoy_profile(root,figs)


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report",type=Path,required=True)
    main(parser.parse_args().report)

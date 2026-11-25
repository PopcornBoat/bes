#!/usr/bin/env python3
"""Prune a backup and reconstruct trace-backed BES graphs without simulator calls."""
import argparse
from collections import Counter, defaultdict, deque
import csv
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from itertools import combinations

HERE = Path(__file__).resolve().parent
TASKS = ("B-line", "Meander", "Sleep")
COLORS = {1:"#4477AA", 2:"#EE7733", 3:"#AA5599", 4:"#228833",
          5:"#44AA99", 6:"#CCBB44", 7:"#332288", 0:"#D9DFE4"}
HOSTS = ("Global","Defender","Enterprise0","Enterprise1","Enterprise2","Op_Server0",
         "User0","User1","User2","User3","User4")
RESPONSES = ("Analyse","Remove","Restore","Decoy")


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def dump(path, obj):
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def csv_read(path, separator="\t"):
    with Path(path).open(newline="", encoding="utf-8") as stream:
        yield from csv.DictReader(stream, delimiter=separator)


def csv_write(path, rows, fields):
    with path.open("w", newline="", encoding="utf-8") as stream:
        w = csv.DictWriter(stream, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)


def archive_rows(source):
    """Yield only the declared policy arm. Coverage/provenance is supplied in the manifest."""
    path = Path(source["path"])
    fmt = source["format"]
    if fmt == "native":
        stream_factory = gzip.open if path.suffix == ".gz" else open
        with stream_factory(path,"rt",encoding="utf-8") as stream:
            for line in stream:
                row=json.loads(line)
                assert row["schema"]=="bes-activation-v1"
                if row["task"]==source["task"] and row["step"]>=source.get("opening_steps",3):
                    yield (row["root"],str(row["episode"]),row["horizon"],row["obs"],row["mask"],
                           str(row["concrete"]),row["ranking"],row.get("rank"),row.get("pair"))
        return
    if fmt == "preimpact":
        with gzip.open(path, "rt", encoding="utf-8") as stream:
            for line in stream:
                episode = json.loads(line)
                for row in episode["steps"][3:]:
                    yield (episode["root"], str(episode["episode"]), 100, row["obs"],
                           int(row["mask"]), str(row["action"]), row["top8"], None, None)
        return
    if fmt == "router":
        for row in csv_read(path):
            if row["label"] == source["label"] and row["decision"] == "3" and row["split"] != "fit":
                yield (source["cohort"], row["seed"], 4, row["obs62"], None, "",
                       "class=" + str(TASKS.index(source["task"])), None, None)
        return
    for row in csv_read(path):
        if fmt == "paired" and row["BEHAVIOR"] == "TPG" and int(row["STEP"]) >= 3:
            h = int(row["HORIZON"])
            if h not in source.get("horizons", [30, 50, 100]):
                continue
            raw = "".join(str(int(float(x.lower().replace("d", "e"))))
                          for x in row["OBSERVATION"].split(","))
            ranking = row["TPG_TOP8"].replace(",", ":").replace(";", ",")
            yield (int(row["SEED_ROOT"]), row["SEED"], h, raw,
                   int(row["DECOY_MASK_BEFORE"]), row["EXECUTED_CONCRETE"], ranking, None, None)
        elif fmt == "worker" and row["arm"] == source["arm"] and int(row["step"]) >= 3:
            h = int(row["horizon"])
            if h in source.get("horizons", [30, 50, 100]):
                yield (source["cohort"], row["seed"], h, row["obs"], int(row["mask"]),
                       row["concrete"], row.get("native_top8", row.get("top8", "")).replace(";", ","),
                       row.get("rank"), row.get("pair"))


def contexts(sources):
    for source in sources:
        task = source["task"]
        profile = source.get("profile", "nil")
        mode = source.get("resolution", "nil")
        for cohort, ep, h, obs, mask, action, ranking, rank, pair in archive_rows(source):
            if len(obs) != 62 or not set(obs) <= {"0", "1", "2"}:
                raise ValueError(f"Unsupported observation {obs!r}")
            yield task, str(cohort), f"{h}/{ep}", (obs, mask, profile, mode), action, ranking, rank, pair


def read_graph(pruning_rows):
    teams = {}
    learners = {}
    edges = []
    for row in pruning_rows:
        team, learner, target = row["team"], row["learner"], row["target"]
        teams.setdefault(team, []).append(learner)
        if learner in learners:
            raise ValueError(f"Duplicate serialized learner slot {learner}")
        learners[learner] = row
        edges.append((team, learner))
        edges.append((learner, target if row["kind"] == "team" else "action/" + learner))
    for row in learners.values():
        if row["kind"] == "team" and row["target"] not in teams:
            raise ValueError(f"Unresolved team reference {row['target']}")
    return {"root":next(iter(teams)), "teams":teams, "learners":learners,
            "actions":{f"action/{id}":row["target"] for id,row in learners.items() if row["kind"]=="action"},
            "edges":edges}


def team_depth(graph):
    root = graph["root"]
    parents = Counter()
    children = {t:[] for t in graph["teams"]}
    for row in graph["learners"].values():
        if row["kind"] == "team":
            children[row["team"]].append(row["target"])
            parents[row["target"]] += 1
    distance = {root:0}
    q = deque([root])
    while q:
        team = q.popleft()
        for child in children[team]:
            if child not in distance:
                distance[child] = distance[team] + 1
                q.append(child)
    assert set(distance) == set(children)
    q = deque(t for t in children if parents[t] == 0)
    longest = {root:1}
    n = 0
    while q:
        t = q.popleft()
        n += 1
        for child in children[t]:
            longest[child] = max(longest.get(child, 0), longest.get(t, 1) + 1)
            parents[child] -= 1
            if parents[child] == 0:
                q.append(child)
    return distance, max(longest.values()) if n == len(children) else None


def nodes_in(path, rank, graph, ranking=None):
    PathTeams = set()
    cursor = graph["root"]
    for i, learner in enumerate(path):
        data = graph["learners"][learner]
        assert data["team"] == cursor
        PathTeams.add(cursor)
        if i + 1 < len(path):
            assert data["kind"] == "team"
            cursor = data["target"]
        else:
            assert data["kind"] == "action"
            if ranking is not None:
                assert data["target"] == ranking[rank]
    return PathTeams


def concrete_pair(action):
    action = int(action)
    if action==1:
        return "0:0"
    offsets = (0,1,2,3,7,8,9,10,11,12)
    for response,base in enumerate((2,15,132,28)):
        size = action-base
        if response==3 and 28<=action<132:
            size %= 13
        elif not 0<=size<13:
            continue
        if size in offsets:
            return f"{offsets.index(size)+1}:{response}"
    return None


def collect_activity(graph, sources, keys, lookup):
    counts = defaultdict(Counter)
    episode_sets = defaultdict(set)
    nodes_by_cohort = defaultdict(set)
    learners_by_cohort = defaultdict(set)
    work = {}
    outcomes = defaultdict(Counter)
    gaps = Counter()
    decisions = Counter()
    cohort_decisions = Counter()
    episodes = defaultdict(set)
    expenses = defaultdict(Counter)
    observed_max_depth = 0
    for task, cohort, episode, ctx, expected, archived_top, archived_rank, archived_pair in contexts(sources):
        row = lookup[keys[ctx]]
        ranking, paths, unpacked = row["ranked"], row["paths"], row["evaluated"]
        if archived_top and ",".join(ranking) != archived_top:
            gaps[(task, cohort, "ranking_mismatch")] += 1
            continue
        decisions[task] += 1
        cohort_decisions[(task,cohort)] += 1
        episodes[task].add((cohort, episode))
        observed_max_depth = max(observed_max_depth, len(paths[0]))
        expenses[task]["evaluated_teams"] += len(unpacked)
        if ctx not in work:
            evaluated = set().union(*(graph["teams"][team] for team in unpacked))
            work[ctx] = (evaluated, set().union(*paths),
                         sum(int(graph["learners"][x]["stored"]) for x in evaluated),
                         sum(int(graph["learners"][x]["kept"]) for x in evaluated))
        evaluated_learners, selected, original_work, pruned_work = work[ctx]
        expenses[task]["programs_evaluated"] += len(evaluated_learners)
        expenses[task]["instructions_original"] += original_work
        expenses[task]["instructions_pruned"] += pruned_work
        expenses[task]["top1_path_length"] += len(paths[0])
        rank = int(row["rank"]) if row["rank"] != "-" else None
        # Archived delivery must agree with independently reconstructed Controller
        # resolution before claiming a terminal path.
        delivered = ()
        if expected and expected != row["concrete"]:
            gaps[(task,cohort,"controller_replay_difference")] += 1
        native_pair = concrete_pair(expected) if expected else None
        if archived_rank and archived_rank.isdigit() and archived_pair:
            rank = int(archived_rank)
            if 0<=rank<len(paths) and ranking[rank]==archived_pair==native_pair:
                delivered = paths[rank]
                if rank != 0:
                    gaps[(task,cohort,"delivered_non_top1")] += 1
            else:
                gaps[(task,cohort,"archived_delivery_unattributed")] += 1
        elif expected and expected == row["concrete"] and row["resolution"] == "candidate":
            assert rank is not None and 0 <= rank < len(paths)
            delivered = paths[rank]
            if rank != 0:
                gaps[(task,cohort,"delivered_non_top1")] += 1
        elif expected:
            gaps[(task,cohort,"unattributed_"+row["resolution"])] += 1
        for event, learner_ids in (("evaluated",evaluated_learners), ("selected",selected),
                                   ("top1",set(paths[0])), ("delivered",set(delivered))):
            team_ids = set()
            learners_by_cohort[(task,cohort,event)].update(learner_ids)
            for id in learner_ids:
                counts[(task,"learner",id)][event] += 1
                episode_sets[(task,"learner",id,event)].add((cohort,episode))
                team_ids.add(graph["learners"][id]["team"])
            for team in team_ids:
                counts[(task,"team",team)][event] += 1
                episode_sets[(task,"team",team,event)].add((cohort,episode))
                nodes_by_cohort[(task,cohort,event)].add(team)
                if event=="delivered":
                    outcomes[(task,team,event)][(ranking[rank],expected)] += 1
    return dict(counts=counts,episode_sets=episode_sets,nodes_by_cohort=nodes_by_cohort,
                learners_by_cohort=learners_by_cohort,outcomes=outcomes,gaps=gaps,decisions=decisions,episodes=episodes,
                cohort_decisions=cohort_decisions,expenses=expenses,observed_max_depth=observed_max_depth)


def task_sets(graph, activity, event):
    tasks = [t for t in TASKS if t in activity["decisions"]]
    tasks += sorted(set(activity["decisions"]) - set(tasks))
    members = {t:{team for team in graph["teams"] if activity["counts"].get((t,"team",team),{}).get(event)}
               for t in tasks}
    regions = {}
    for size in range(1,len(tasks)+1):
        for combination in combinations(tasks,size):
            both = set.intersection(*(members[t] for t in combination))
            both -= set.union(set(), *(members[t] for t in tasks if t not in combination))
            regions[" + ".join(combination)] = len(both)
    assert sum(regions.values()) == len(set.union(set(),*members.values()))
    return {"sets":{k:sorted(v) for k,v in members.items()}, "exclusive_regions":regions,
            "root_in_every_task":bool(tasks) and all(graph["root"] in members[t] for t in tasks)}


def formats():
    return ("svg", "pdf", "png")


def graph_dot(graph, activity, out, event, full=False):
    tasks = list(TASKS) + sorted(set(activity["decisions"]) - set(TASKS))
    observed_tasks = [t for t in tasks if t in activity["decisions"]]
    counts = activity["counts"]
    layers, _ = team_depth(graph)
    def node_type(node):
        if node in graph["teams"]:
            return "team", node
        if node in graph["learners"]:
            return "learner", node
        return "learner", node.removeprefix("action/")
    def mask(node):
        kind, key = node_type(node)
        return sum(1<<i for i,t in enumerate(tasks) if counts.get((t,kind,key),{}).get(event))
    nodes = list(graph["teams"]) + list(graph["learners"]) + list(graph["actions"])
    nodes = [x for x in nodes if full or mask(x)]
    if not nodes:
        return False
    drawn = set(nodes)
    large = len(nodes) > 400
    columns = defaultdict(list)
    for node in nodes:
        if node in graph["teams"]:
            layer = 2 * layers[node]
        else:
            _, key = node_type(node)
            layer = 2 * layers[graph["learners"][key]["team"]] + (2 if node in graph["actions"] else 1)
        columns[layer].append(node)
    position = {node: f"{layer*105},{(len(nodes_in_column)/2-i)*19}!"
                for layer, nodes_in_column in columns.items() for i,node in enumerate(nodes_in_column)}
    quoted = json.dumps
    with out.open("w", encoding="utf-8") as f:
        f.write('digraph policy {\ngraph [rankdir=LR,bgcolor=white,pad=0.22,fontname="Arial",overlap=true,labeljust=l];\n')
        f.write('node [fontname="Arial",fontsize=10,style=filled,color="#697583"];\nedge [color="#9AA6AF",arrowsize=0.42,penwidth=0.55];\n')
        present = sorted({mask(node) for node in nodes if mask(node)})
        legend = " | ".join("+".join(t for i,t in enumerate(tasks) if item & (1<<i)) for item in present)
        if not observed_tasks:
            legend = "No activation trace supplied"
        title = event.title()+" paths | "+legend+"\nCircle: Team   { }: Program   Rectangle: atomic action"
        f.write(f'graph [label={quoted(title)}];\n')
        for node in nodes:
            fill = COLORS.get(mask(node), "#576475")
            if node in graph["teams"]:
                shape, label = "circle", ("Root" if node==graph["root"] else ("" if large else node))
            elif node in graph["learners"]:
                shape,label = "plaintext","{ }"
            else:
                shape,label = "box",graph["actions"][node]
                if label.startswith("class="):
                    label = TASKS[int(label.split("=")[1])]
                elif not large:
                    host, response = map(int,label.split(":"))
                    label = "Monitor" if host == 0 else f"{HOSTS[host]} {RESPONSES[response]}"
            root = node == graph["root"]
            tooltip = f"{node}: " + "; ".join(f'{t}={counts.get((t,*node_type(node)),{}).get(event,0)}' for t in tasks)
            attrs = [f"shape={shape}",f"label={quoted(label)}",f"fillcolor={quoted(fill)}",
                     f"tooltip={quoted(tooltip)}"]
            if node in graph["learners"]:
                attrs += ['fillcolor=white','style=solid',
                          f"fontcolor={quoted(fill if mask(node) else '#8A969F')}",
                          'width=0.16','height=0.15','margin=0']
            if root:
                attrs += ['penwidth=2.7','peripheries=2','color="#1C2432"',
                          'fontcolor=white' if mask(node) else 'fontcolor="#1C2432"']
            if large:
                attrs += [f"pos={quoted(position[node])}",'width=0.16','height=0.15','fontsize=8']
            f.write(f'{quoted(node)} [{",".join(attrs)}];\n')
        for a,b in graph["edges"]:
            if a in drawn and b in drawn:
                f.write(f"{quoted(a)} -> {quoted(b)};\n")
        f.write("}\n")
    return large


def render(dot, output, engine, kinds, large):
    layout = "neato" if large else "dot"
    for kind in kinds:
        target = output.with_suffix(f".{kind}")
        args = [engine, f"-K{layout}", f"-T{kind}"]
        if large:
            args += ["-n2"]
        if kind == "png" and large:
            args += ["-Gsize=24,20", "-Gdpi=100"]
        with dot.open("rb") as source,target.open("wb") as image:
            subprocess.run(args,stdin=source,stdout=image,check=True)


def render_views(graph,activity,overlaps,output,engine,mode):
    views = [("full-graph","selected",True,("svg",))]
    if mode == "activation" and activity["decisions"]:
        views += [("policy-graph","selected",False,formats()),("top1-graph","top1",False,formats()),
                  ("delivered-graph","delivered",False,formats())]
    for name,event,full,kinds in views:
        if full or any(overlaps[event]["sets"].values()):
            dot = output/f"{name}.dot"
            large = graph_dot(graph,activity,dot,event,full)
            render(dot,output/name,engine,kinds,large)


def run_audit(checkpoint, output, code, sources, engine, mode, reuse=False):
    output.mkdir(parents=True,exist_ok=reuse)
    if checkpoint.resolve() in output.resolve().parents:
        raise ValueError("Output must be a separate directory")
    baseline_hash = sha(checkpoint)
    copy = output/"backup"/checkpoint.name
    if not reuse:
        copy.parent.mkdir()
        shutil.copyfile(checkpoint,copy)
        copy.chmod(0o444)
    assert sha(copy) == baseline_hash
    pruned = output/(checkpoint.stem+"-pruned.lisp")
    prune_table = output/"instruction-prune.tsv"
    deps = os.environ.get("BES_ASDF_DEPENDENCIES")
    trees = ([Path(deps)] if deps else [Path.home()/"quicklisp/local-projects",
                                        Path.home()/"quicklisp/dists/quicklisp/software"])
    paths = " ".join(f'(:tree "{p}/")' for p in trees)
    env = {**os.environ, "CL_SOURCE_REGISTRY":f'(:source-registry (:directory "{code}/") {paths} :ignore-inherited-configuration)'}
    with (output/"verification.log").open("a" if reuse else "w",encoding="utf-8") as log:
        def lisp(*args):
            subprocess.run(["sbcl","--dynamic-space-size","2048","--script",str(HERE/"checkpoint-audit.lisp"),
                            *map(str,args)],check=True,env=env,stdout=log,stderr=log)
        if reuse:
            previous = json.loads((output/"summary.json").read_text())
            assert previous["pruned_sha256"] == sha(pruned)
        else:
            lisp("prune",copy,pruned,prune_table)
            pruned.chmod(0o444)
        graph = read_graph(csv_read(prune_table))
        dump(output/"graph-structure.json",graph)
        summary = {"checkpoint":str(checkpoint),"original_sha256":baseline_hash,"pruned_sha256":sha(pruned),
                   "root":graph["root"],"teams":len(graph["teams"]),"learners":len(graph["learners"]),
                   "atomic_terminals":len(graph["actions"]),"edges":len(graph["edges"]),
                   "max_graph_depth":team_depth(graph)[1],"sources":sources,
                   "program_counts":{k:sum(int(r[k]) for r in graph["learners"].values())
                                     for k in ("stored","structural_live","kept")}}
        keys = {}
        for _,_,_,ctx,*_ in contexts(sources):
            keys.setdefault(ctx,len(keys))
        if keys:
            input_file = output/"contexts.sexp"
            query_text = "".join(f'({i} "{obs}" {mask if mask is not None else "nil"} {profile} {resolution})\n'
                                 for (obs,mask,profile,resolution),i in keys.items())
            trace_file = output/"verified-context-paths.tsv"
            if reuse:
                assert input_file.read_text() == query_text, "Archive context IDs changed"
            else:
                input_file.write_text(query_text,encoding="utf-8")
                lisp("replay",copy,pruned,input_file,trace_file)
            lookup = {}
            for row in csv_read(trace_file):
                row["ranked"] = row["ranking"].split(",")
                row["paths"] = [tuple(path.split(",")) for path in row["paths"].split(";")]
                row["evaluated"] = set(row["evaluated_teams"].split(","))
                assert len(row["ranked"]) == len(row["paths"]) == len(set(row["ranked"]))
                for rank,path in enumerate(row["paths"]):
                    assert nodes_in(path,rank,graph,row["ranked"]) <= row["evaluated"]
                lookup[int(row["id"])] = row
            assert len(lookup) == len(keys)
            activity = collect_activity(graph,sources,keys,lookup)
        else:
            activity = collect_activity(graph,[],{},{})

    counts = activity["counts"]
    for category in ("team","learner"):
        rows = []
        for task in activity["decisions"]:
            for id in graph[category+"s"]:
                record = {"task":task,category:id}
                counts_for_node = counts.get((task,category,id),{})
                for event in ("evaluated","selected","top1","delivered"):
                    record[event] = counts_for_node.get(event,0)
                    record[event+"_episodes"] = len(activity["episode_sets"].get((task,category,id,event),()))
                record["selected_rate"] = record["selected"]/activity["decisions"][task]
                if category == "team":
                    learners = graph["teams"][id]
                    record["children"] = json.dumps([graph["learners"][l]["target"] for l in learners
                                                      if graph["learners"][l]["kind"]=="team"])
                    record["selected_learners"] = json.dumps({l:counts.get((task,"learner",l),{}).get("selected",0)
                                                               for l in learners if counts.get((task,"learner",l),{}).get("selected",0)})
                    record["delivered_outcomes"] = json.dumps({f"{a} -> {c}":n for (a,c),n in
                                                                activity["outcomes"].get((task,id,"delivered"),{}).items()},
                                                               ensure_ascii=False)
                rows.append(record)
        base = ["task",category,*(name for stage in ("evaluated","selected","top1","delivered")
                                  for name in (stage,stage+"_episodes")),"selected_rate"]
        csv_write(output/f"{category}-activation.csv",rows,base+
                  (["children","selected_learners","delivered_outcomes"] if category=="team" else []))
    overlaps = {stage:task_sets(graph,activity,stage) for stage in ("selected","top1","delivered")}
    dump(output/"task-overlap.json",overlaps)
    summary.update({"verified_unique_contexts":len(keys),"decisions":activity["decisions"],
                    "episodes":{t:len(v) for t,v in activity["episodes"].items()},
                    "max_observed_path_depth":activity["observed_max_depth"],
                    "runtime_per_decision":{t:{k:v/activity["decisions"][t] for k,v in e.items()}
                                            for t,e in activity["expenses"].items()},
                    "coverage_by_cohort":{f"{t}/{root}/{event}":sorted(nodes)
                                           for (t,root,event),nodes in activity["nodes_by_cohort"].items()},
                    "learner_coverage_by_cohort":{f"{t}/{root}/{event}":sorted(nodes)
                                                   for (t,root,event),nodes in activity["learners_by_cohort"].items()},
                    "coverage_decisions":{f"{t}/{root}":n for (t,root),n in activity["cohort_decisions"].items()},
                    "trace_accounting":{f"{t}/{root}/{reason}":n for (t,root,reason),n in activity["gaps"].items()}})
    assert sha(checkpoint)==sha(copy)==baseline_hash
    dump(output/"summary.json",summary)
    render_views(graph,activity,overlaps,output,engine,mode)
    return summary


def rerender(output,engine,mode="activation"):
    graph=json.loads((output/"graph-structure.json").read_text())
    overlap=json.loads((output/"task-overlap.json").read_text())
    summary=json.loads((output/"summary.json").read_text())
    counts={}
    for category in ("team","learner"):
        for row in csv_read(output/f"{category}-activation.csv",","):
            counts[row["task"],category,row[category]]={key:int(row[key]) for key in
                                                       ("evaluated","selected","top1","delivered")}
    render_views(graph,{"counts":counts,"decisions":summary["decisions"]},overlap,output,engine,mode)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--checkpoint",type=Path)
    p.add_argument("--traces",type=Path,help="JSON array of trace source descriptors")
    p.add_argument("--output",type=Path,required=True)
    p.add_argument("--code",type=Path,help="Pinned cl-tpg source directory")
    p.add_argument("--render-only",action="store_true",help="Render from exported structure and activity tables")
    p.add_argument("--graphviz", default=shutil.which("dot") or shutil.which("dot.exe"))
    p.add_argument("--mode",choices=("activation","full"),default="activation")
    p.add_argument("--reuse-audit",action="store_true",help="Rebuild derived data from existing verified contexts")
    args = p.parse_args()
    if not args.graphviz:
        p.error("Graphviz dot not found")
    if args.render_only:
        rerender(args.output,args.graphviz,args.mode)
        return
    if args.checkpoint is None or args.code is None:
        p.error("--checkpoint and --code are required for an audit")
    sources = json.loads(args.traces.read_text()) if args.traces else []
    checkpoint_digest = sha(args.checkpoint)
    for source in sources:
        if checkpoint_digest != source["checkpoint_sha256"]:
            p.error(f"Checkpoint hash differs from source {source['path']}")
        if "source_sha256" in source and sha(source["path"]) != source["source_sha256"]:
            p.error(f"Trace content hash changed: {source['path']}")
    run_audit(args.checkpoint.resolve(),args.output.resolve(),args.code.resolve(),
              sources,args.graphviz,args.mode,args.reuse_audit)

if __name__=="__main__":
    main()

#!/usr/bin/env python3
"""Run complete BES and Cardiff agents in the installed CAGE2 evaluator."""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[1]
ARTIFACTS = Path(os.environ.get("BES_ARTIFACTS_ROOT", Path.home() / "bes-artifacts"))
RUNTIME = ARTIFACTS / "runtime"
BES = RUNTIME / "bes-opponent-dispatch-best-20261116"
CARDIFF = RUNTIME / "cardiff-official-mainagent-20261116"
VENV = Path(os.environ.get("BES_PYTHON_VENV", Path.home() / "venv-base/cage2_bridge/.venv"))
PLOT = RUNTIME / ".validation-plot-venv/bin/python"
RED = ("B_lineAgent", "RedMeanderAgent", "SleepAgent")
HORIZONS = (30, 50, 100)
SEED = 153
EPISODES = 1000
AGENTS = ("bes", "cardiff")
INPUT_KEYS = ("router", "b_line", "meander")
LABELS = {"b-line": "bline", "bline": "bline", "meander": "meander", "sleep": "sleep", "opening": "opening"}

def read(path):
    return json.loads(path.read_text())

def save(path, data):
    path.write_text(json.dumps(data, indent=2, allow_nan=False) + "\n")

def sha(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()

def table(path):
    with path.open(newline="") as f:
        yield from csv.DictReader(f, delimiter="\t")

def spec(*, legacy_checkout=None, weights_variant="local-90000", seed_root=SEED, require_cardiff=True):
    from CybORG import CYBORG_VERSION, CybORG
    import inspect
    source = Path(inspect.getfile(CybORG)).resolve().parent
    cardiff = read(CARDIFF / "manifest.json")
    official = source / "Evaluation/evaluation.py"
    assert CYBORG_VERSION == cardiff["cyborg_version"]
    cyborg_commit = cardiff["cyborg_commit"]
    if legacy_checkout is not None:
        cyborg_commit = "f12ff493cd3b8327cab93f645d71330e7b282377"
        assert source == legacy_checkout.resolve() / "CybORG/CybORG", source
        revision = subprocess.check_output(
            ["git", "-C", str(legacy_checkout), "rev-parse", "HEAD"], text=True
        ).strip()
        assert revision == cyborg_commit, revision
        subprocess.run(["git", "-C", str(legacy_checkout), "diff", "--exit-code", "HEAD", "--", "CybORG"],
                       check=True)

    for relative, key in (("Evaluation/evaluation.py", "official_script_sha256"),
                          ("Shared/Scenarios/Scenario2.yaml", "scenario_sha256"),
                          ("Agents/Wrappers/ChallengeWrapper.py", "wrapper_sha256"),
                          ("Agents/Wrappers/BlueTableWrapper.py", "blue_table_sha256")):
        assert sha(source / relative) == cardiff[key], key
    bes_inputs = read(BES / "full/plan.json")["inputs"]
    for item in bes_inputs.values():
        assert sha(Path(item["path"])) == item["sha256"]
    if require_cardiff:
        for opponent, value in cardiff["weights"][weights_variant].items():
            assert sha(CARDIFF / weights_variant / "Models" / opponent / "model.pth") == value
    frozen = ARTIFACTS / "frozen-checkpoints/meander-v14-manual-fix"
    lisp = [
        REPO / "scripts/post-opening-router.lisp",
        REPO / "scripts/expert-dispatch.lisp",
        *(frozen / name for name in ("support.lisp", "route-helpers.lisp", "catalogue-helpers.lisp", "evaluate.lisp")),
        RUNTIME / "bline-balanced-action-credit-20261115/candidate.lisp",
        RUNTIME / "bline-restore-context-policy-20261116/evaluate.lisp",
        BES / "experts.lisp",
        REPO / "scripts/full-validation-agent.lisp",
    ]
    return dict(seed_root=seed_root, reset_protocol="official continuous ChallengeWrapper.reset",
                cyborg_commit=cyborg_commit, episodes_per_cell=EPISODES, horizon=HORIZONS, opponents=RED,
                bes_inputs=bes_inputs, bes_code={str(p):sha(p) for p in lisp},
                cardiff_weights=cardiff["weights"][weights_variant] if require_cardiff else None,
                cardiff_weights_variant=weights_variant if require_cardiff else None,
                cardiff_mainagent_sha256=sha(CARDIFF / "cardiff-source/Agents/MainAgent.py") if require_cardiff else None,
                official_source=str(official), version=CYBORG_VERSION,
                official_script_sha256=sha(official), planned_transitions=2*len(RED)*sum(HORIZONS)*EPISODES,
                historical_total={"bes":-57.7761, "cardiff":-57.5474},
                meander_route_discovery_seed_root=153)

def sexp_path(path):
    return json.dumps(str(path))


class BESAgent:
    def __init__(self, protocol, folder, *, allow_shadow=False):
        dependencies = os.environ.get("BES_ASDF_DEPENDENCIES")
        library = f'(:tree "{dependencies}/") ' if dependencies else ""
        env = dict(os.environ, CL_SOURCE_REGISTRY=
                   f'(:source-registry (:directory "{REPO}/") {library}:ignore-inherited-configuration)')
        env["PATH"] = str(VENV / "bin") + os.pathsep + env["PATH"]
        command = ["sbcl", "--dynamic-space-size", "1536", "--noinform", "--non-interactive",
                   "--eval", "(require :asdf)", "--eval", "(asdf:load-system :cl-tpg)"]
        for path in protocol["bes_code"]:
            command.extend(("--load", path))
        args = " ".join(json.dumps(protocol["bes_inputs"][key]["path"]) for key in INPUT_KEYS)
        if allow_shadow or protocol.get("manual_patch"):
            raise ValueError("Graph-only validation accepts no policy overrides")
        command.extend(("--eval", f"(cl-tpg::full-validation-agent-server {args})"))
        self.log = (folder / "bes-agent.log").open("w")
        self.process = subprocess.Popen(command, text=True, bufsize=1, cwd=REPO,
                                        env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.log)
        try:
            assert self.receive() == "ready"
            self.end_episode()
        except BaseException:
            self.close()
            raise

    def receive(self):
        for line in self.process.stdout:
            if line.startswith("AGENT "):
                return line[6:].strip()
            self.log.write(line)
            self.log.flush()
        raise RuntimeError(f"BES agent exited with code {self.process.poll()}. See {self.log.name}")

    def send(self, line):
        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()
        return self.receive()

    def get_action(self, obs, action_space):
        concrete, route, top, effective = self.send("obs " + "".join(str(int(x)) for x in obs)).split()
        self.info = LABELS[route], top, effective
        return int(concrete)

    def commit(self, action):
        assert self.send(f"commit {action}") == "ok"

    def end_episode(self):
        assert self.send("reset") == "ok"

    def close(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.write("quit\n")
                self.process.stdin.flush()
                self.process.wait(timeout=8)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait()
        self.log.close()

def materialize(protocol, arm, count, folder):
    script = Path(protocol["official_source"]).read_text()
    def replace(old, new):
        nonlocal script
        assert script.count(old) == 1, old
        script = script.replace(old, new)
    replace("MAX_EPS = 100", f"MAX_EPS = {count}")
    replace("commit_hash = get_git_revision_hash()", f"commit_hash = {protocol['cyborg_commit']!r}")
    replace("name = input('Name: ')", 'name = "Local evaluation"')
    replace('team = input("Team: ")', f"team = {arm!r}")
    replace('name_of_agent = input("Name of technique: ")', f"name_of_agent = {arm!r}")
    replace("from CybORG.Agents.SimpleAgents.BlueLoadAgent import BlueLoadAgent\n", "")
    replace("agent = BlueLoadAgent()", "agent = injected_agent")
    line = next(x for x in script.splitlines() if x.strip().startswith("file_name = "))
    replace(line, f"    file_name = {str(folder / 'official-evaluation.txt')!r}")
    seed_root = protocol["seed_root"]
    replace("    for num_steps in [30, 50, 100]:",
            f"    import random\n    random.seed({seed_root})\n    for num_steps in [30, 50, 100]:")
    replace("                    r.append(rew)",
            "                    r.append(rew)\n"
            "                    record_action(num_steps, red_agent.__name__, i, j, action, rew)")
    replace("                total_reward.append(sum(r))",
            "                total_reward.append(sum(r))\n"
            "                record_episode(num_steps, red_agent.__name__, i, total_reward[-1])")
    path = folder / "evaluation.py"
    path.write_text(script)
    return path

def worker(arm, folder, count, *, legacy_checkout=None, weights_variant="local-90000",
           manual_patch=None, seed_root=SEED, experimental_bline_patch=False,
           compiled_meander=None, compiled_meander_observations=67,
           compiled_meander_preserve_routes=False):
    import runpy
    from contextlib import ExitStack, nullcontext
    protocol = spec(legacy_checkout=legacy_checkout, weights_variant=weights_variant, seed_root=seed_root,
                    require_cardiff=(arm == "cardiff"))
    if experimental_bline_patch:
        assert arm == "bes" and manual_patch is not None
        protocol["experimental_bline_patch"] = True
    if manual_patch:
        assert arm == "bes"
        protocol["manual_patch"] = {"path":str(manual_patch), "sha256":sha(manual_patch)}
    if compiled_meander is not None:
        assert arm == "bes" and manual_patch is None
        assert compiled_meander_observations in (62, 67)
        protocol["bes_inputs"]["meander"] = dict(path=str(compiled_meander), sha256=sha(compiled_meander))
        assert not compiled_meander_preserve_routes or compiled_meander_observations == 62
        protocol["experimental_compiled_restore_priority"] = not compiled_meander_preserve_routes
        protocol["experimental_compiled_branch_audit"] = compiled_meander_preserve_routes
        protocol["experimental_compiled_restore_mask"] = (compiled_meander_observations == 67)
        protocol["compiled_meander_observations"] = compiled_meander_observations
    folder.mkdir(parents=True, exist_ok=False)
    save(folder / "manifest.json", protocol)
    if compiled_meander is not None:
        display_name = f"bes-compiled-meander-{compiled_meander_observations}"
        if compiled_meander_preserve_routes:
            display_name += "-original-routes"
    elif arm == "bes":
        display_name = "bes-patched" if manual_patch else "bes"
    else:
        display_name = f"cardiff-{weights_variant}"
    path = materialize(protocol, display_name, count, folder)
    start = time.monotonic()
    with ExitStack() as stack:
        if arm == "bes":
            agent = BESAgent(protocol, folder)
            stack.callback(agent.close)
            mode = nullcontext()
        else:
            import torch
            torch.set_num_threads(1)
            sys.path.insert(0, str(CARDIFF / "cardiff-source"))
            os.chdir(CARDIFF / weights_variant)
            from Agents.MainAgent import MainAgent
            agent = MainAgent()
            mode = torch.inference_mode()
        trace = stack.enter_context((folder/"actions.tsv").open("w", newline=""))
        episodes = stack.enter_context((folder/"episodes.tsv").open("w", newline=""))
        tw, ew = (csv.writer(f, delimiter="\t") for f in (trace, episodes))
        tw.writerow(("horizon","red","episode","step","concrete","reward","route","native_top1","effective_top1"))
        ew.writerow(("horizon","red","episode","reward"))
        patch_hits = Counter()
        event_log = None
        if manual_patch:
            event_log = stack.enter_context((folder/"patch-events.tsv").open("w",newline=""))
            event_writer = csv.writer(event_log,delimiter="\t")
            event_writer.writerow(("horizon","red","episode","step","concrete","reward"))

        native_hits = Counter()
        native_deliveries = Counter()
        native_event_file = ("native-branch-events.tsv" if compiled_meander_preserve_routes
                             else "native-priority-events.tsv")
        native_hit_command = ("native-branch-hit" if compiled_meander_preserve_routes
                              else "native-priority-hit")
        if compiled_meander is not None:
            priority_log = stack.enter_context((folder/native_event_file).open("w",newline=""))
            priority_writer = csv.writer(priority_log,delimiter="\t")
            priority_writer.writerow(("horizon","red","episode","step","concrete","reward",
                                      "obs62","decoy_mask","native_top1","effective_top1","restore_delivered"))

        def record_action(h, red, i, step, action, reward):
            action = int(action)
            if arm == "bes":
                route, top, effective = agent.info
                if (compiled_meander is not None and route == "meander"
                        and agent.send(native_hit_command) == "1"):
                    obs, mask = agent.send("context").split()
                    native_hits[h,red] += 1
                    delivered = top.endswith(":2") and top == effective and action >= 132
                    native_deliveries[h,red] += int(delivered)
                    priority_writer.writerow((h,red,i,step,action,reward,obs,mask,top,effective,int(delivered)))
                    priority_log.flush()
                agent.commit(action)
                if (event_log is not None and (route == "meander" or
                        (experimental_bline_patch and route == "bline")) and agent.send("patch-hit") == "1"):
                    patch_hits[h,red] += 1
                    event_writer.writerow((h,red,i,step,action,reward))
                    event_log.flush()
            else:
                route = "opening"
                if agent.agent_loaded:
                    ckpt = getattr(agent.agent, "ckpt", None)
                    route = Path(ckpt).parent.name if ckpt else "sleep"
                top = effective = "-"
            if step < 3:
                assert action == (51,116,55)[step] and route == "opening"
            tw.writerow((h, red, i, step, action, reward, route, top, effective))
        def record_episode(h, red, i, score):
            ew.writerow((h,red,i,score))
            if i == 0 or (i+1) % 50 == 0 or i+1 == count:
                trace.flush()
                episodes.flush()
                print(f"PROGRESS {display_name} {red} {h} steps {i+1}/{count} episodes", flush=True)
        with mode:
            runpy.run_path(str(path),run_name="__main__",init_globals=dict(
                injected_agent=agent,record_action=record_action,record_episode=record_episode))
    result = summarize(folder, count)
    if arm == "cardiff" and count == EPISODES and legacy_checkout is None and seed_root == SEED and (CARDIFF / weights_variant / "full/results.json").is_file():
        old = read(CARDIFF / weights_variant / "full/results.json")
        prior = {(x["horizon"],x["red"]):x["mean"] for x in old["cells"]}
        result["archived_mean_deltas"] = {f"{h}-{r}": a["mean"]-prior[h,r]
                                          for key,a in result["cells"].items()
                                          for h,r in [(int(key.split("-")[0]),key.split("-")[1])]}
    if manual_patch:
        result["patch_hits"] = {f"{h}-{red}":n for (h,red),n in patch_hits.items()}
    if compiled_meander is not None:
        hit_name = "native_branch_hits" if compiled_meander_preserve_routes else "native_priority_hits"
        result[hit_name] = {f"{h}-{red}":n for (h,red),n in native_hits.items()}
        result["native_restore_deliveries"] = {f"{h}-{red}":n for (h,red),n in native_deliveries.items()}
    result["elapsed_seconds"] = time.monotonic()-start
    save(folder/"results.json",result)
    (folder/"DONE").write_text("DONE\n")
    print(f"DONE {display_name} total={result['total']:.6f} actions={result['steps']}",flush=True)

def summarize(folder, count):
    from itertools import product
    scores = {}
    for row in table(folder/"episodes.tsv"):
        key = (int(row["horizon"]), row["red"], int(row["episode"]))
        assert key not in scores
        scores[key] = float(row["reward"])
    assert set(scores) == set(product(HORIZONS, RED, range(count)))
    actual, routes, counts, trace_scores, idx = (Counter() for _ in range(5))
    for row in table(folder/"actions.tsv"):
        key = (int(row["horizon"]),row["red"],int(row["episode"]))
        step = int(row["step"])
        assert key in scores and step == idx[key] and step < key[0]
        idx[key] += 1
        trace_scores[key] += float(row["reward"])
        if step < 3:
            continue
        group = key[:2]
        actual[group, int(row["concrete"])] += 1
        if step == 3:
            routes[group, row["route"]] += 1
        for kind in ("native_top1","effective_top1"):
            if row[kind] != "-":
                counts[group, kind, row[kind]] += 1
    assert all(idx[k] == k[0] and math.isclose(s,trace_scores[k],abs_tol=1e-8) for k,s in scores.items())
    cells = {}
    for h,r in product(HORIZONS,RED):
        values = [scores[h,r,i] for i in range(count)]
        tail_size = max(1,math.ceil(.1*count))
        cells[f"{h}-{r}"] = dict(mean=statistics.mean(values),
            std=statistics.stdev(values),worst=min(values),
            cvar10=statistics.mean(sorted(values)[:tail_size]),below_minus100=sum(x < -100 for x in values),
            episodes=count,post_opening_steps=(h-3)*count,
            concrete_counts={str(a):n for ((hh,rr),a),n in actual.items() if (hh,rr)==(h,r)},
            routes={route:n for ((hh,rr),route),n in routes.items() if (hh,rr)==(h,r)},
            top1={kind:{a:n for ((hh,rr),k,a),n in counts.items() if (hh,rr,k)==(h,r,kind)}
                  for kind in ("native_top1","effective_top1")})
    return dict(cells=cells,total=sum(c["mean"] for c in cells.values()),steps=sum(idx.values()))

def master(output):
    output.mkdir(parents=True, exist_ok=True)
    manifest = spec()
    save(output/"manifest.json", manifest)
    def launch(arm, stage, n):
        folder = output/stage/arm
        if (folder/"DONE").exists():
            return
        folder.parent.mkdir(parents=True, exist_ok=True)
        if folder.exists():
            folder.rename(folder.with_name(f"{arm}-incomplete-{time.time_ns()}"))
        with (folder.parent/f"{arm}.log").open("w") as log:
            subprocess.run([sys.executable,"-u",__file__,"worker",str(folder),arm,str(n)],
                           cwd=REPO,stdout=log,stderr=subprocess.STDOUT,check=True)
    for stage,n in (("smoke",2),("full",EPISODES)):
        print(f"START {stage} episodes_per_cell={n}",flush=True)
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures=[pool.submit(launch,arm,stage,n) for arm in AGENTS]
            for future in futures:
                future.result()
        print(f"DONE {stage}",flush=True)
    dest=Path("/mnt/d/PhD-researches/bes-artifacts/reports") / output.name
    subprocess.run([str(PLOT), __file__, "plot", str(output), str(dest)],check=True)
    (output/"DONE").write_text("DONE\n")
    print(f"DONE full validation and charts: {dest}",flush=True)

def concrete_label(action):
    hosts = ("Defender","Enterprise0","Enterprise1","Enterprise2","Op_Host0","Op_Host1","Op_Host2",
             "Op_Server0","User0","User1","User2","User3","User4")
    if action in (0,1):
        return ("Sleep" if action == 0 else "Monitor", "")
    if not 2 <= action <= 144:
        raise ValueError(f"Unknown official action {action}")
    host=hosts[(action-2)%13]
    response = "Analyse" if action < 15 else "Remove" if action < 28 else "Restore" if action >= 132 else "Decoy"
    return response,host

def prior_bes_comparison(manifest, current, output):
    previous_path = BES / "full/results.json"
    if not previous_path.is_file() or EPISODES != 1000:
        return None
    previous = read(previous_path)
    names = dict(zip(RED, ("b_line", "meander", "sleep")))
    cells = {}
    for key, now in current["cells"].items():
        horizon, red = key.split("-", 1)
        old = previous["cells"][f"{names[red]}-{horizon}"]
        cells[key] = dict(old_mean=old["mean"], new_mean=now["mean"],
                          delta=now["mean"]-old["mean"], old_worst=old["worst"],
                          new_worst=now["worst"])
    values = [float(row["reward"]) for row in table(output/"full/bes/episodes.tsv")
              if row["horizon"]=="100" and row["red"]=="RedMeanderAgent"]
    assert len(values) == EPISODES
    kept = [v for v in values if v >= -100]
    tail = None
    if kept and len(kept) != len(values):
        tail = dict(below_minus100=len(values)-len(kept), worst=min(values),
                    remaining_episode_mean=statistics.mean(kept),
                    delta_to_total=statistics.mean(kept)-statistics.mean(values))
    parity_path = output / "archive-policy-parity.json"
    parity = read(parity_path) if parity_path.is_file() else None
    old_total = sum(row["old_mean"] for row in cells.values())
    return dict(source=str(previous_path), old_total=old_total, new_total=current["total"],
                delta=current["total"]-old_total, cells=cells, meander_100_tail_replacement=tail,
                archived_action_replay=parity,
                same_policy_inputs=previous["input_sha256"] ==
                    {key:item["sha256"] for key,item in manifest["bes_inputs"].items()})

def plot(output,destination):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from analyze_policy_frequency import pair,response
    destination.mkdir(parents=True,exist_ok=True)
    out = {arm:read(output/"full"/arm/"results.json") for arm in AGENTS}
    assert all(d["steps"] == len(RED)*sum(HORIZONS)*EPISODES for d in out.values())
    manifest = read(output/"manifest.json")
    palette = dict(zip(("Analyse","Remove","Restore","Decoy","Monitor","Sleep"),
                       ("#4477AA","#EE7733","#CC3311","#009988","#BBBBBB","#AA4499")))
    def draw(ax, counter, colors, title, total, minimum=0):
        rows=[(k,v) for k,v in counter.most_common() if v/total >= minimum]
        other=total-sum(v for _,v in rows)
        if other:
            rows.append(("Other",other))
        assert sum(v for _,v in rows)==total
        ax.pie([v for k,v in rows],labels=[k for k,v in rows],
               colors=[colors.get(k,"#CCCCCC") for k,v in rows],
               autopct=lambda p:f"{p:.1f}%" if p>=1 else "", startangle=90,
               textprops={"fontsize":8},pctdistance=.72)
        ax.set_title(title,fontsize=10)
    with (destination/"action-frequencies.tsv").open("w",newline="") as f:
        w=csv.writer(f,delimiter="\t")
        w.writerow(("agent","horizon","opponent","measure","action","count","denominator"))
        for arm,result in out.items():
            for key,cell in result["cells"].items():
                h,r=key.split("-")
                tables=dict(concrete=cell["concrete_counts"],**cell["top1"])
                for measure,counts in tables.items():
                    for action,count in counts.items():
                        w.writerow((arm,h,r,measure,action,count,sum(counts.values())))
    def save_figure(fig, name):
        fig.tight_layout(rect=(0, 0, 1, .93))
        for ext in ("png", "svg"):
            fig.savefig(destination / f"{name}.{ext}", dpi=175, bbox_inches="tight")
        plt.close(fig)

    def executed_counts(cell, detailed=False):
        counter = Counter()
        for concrete, count in cell["concrete_counts"].items():
            verb, host = concrete_label(int(concrete))
            name = f"{host} {verb}" if detailed and host else verb
            counter[name] += count
        return counter

    def winner_counts(cell, measure):
        counter = Counter()
        for action, count in cell["top1"][measure].items():
            counter[response(pair(action))] += count
        return counter

    opponent_name = dict(zip(RED, ("B-line", "Meander", "Sleep")))
    agent_name = {"bes": "BES / TPG", "cardiff": "Cardiff / PPO"}
    combinations = [(arm, red) for red in RED[:2] for arm in AGENTS]
    # Share one color assignment for the same semantic action across all panels.
    semantic_labels = sorted({action for result in out.values()
                              for cell in result["cells"].values()
                              for action in executed_counts(cell, detailed=True)})
    semantic_colors = {action: plt.get_cmap("tab20")(index % 20)
                       for index, action in enumerate(semantic_labels)}

    for detailed in (False, True):
        fig, axes = plt.subplots(3, 4, figsize=(18, 12))
        for i, h in enumerate(HORIZONS):
            for j, (arm, red) in enumerate(combinations):
                cell = out[arm]["cells"][f"{h}-{red}"]
                counts = executed_counts(cell, detailed)
                draw(axes[i, j], counts, semantic_colors if detailed else palette,
                     f"{agent_name[arm]} · {opponent_name[red]} · {h} steps",
                     cell["post_opening_steps"], .025 if detailed else 0)
        fig.suptitle("Official full validation · executed " + ("host and response" if detailed else "response") +
                     "\\nB-line and Meander · 1,000 episodes per cell · fixed opening excluded")
        save_figure(fig, "executed-host-response" if detailed else "executed-responses")

    fig, axes = plt.subplots(2, 3, figsize=(15, 9))
    for i, red in enumerate(RED[:2]):
        cell = out["bes"]["cells"][f"100-{red}"]
        panels = (("Native TPG Top-1", winner_counts(cell, "native_top1")),
                  ("Top-1 after repair", winner_counts(cell, "effective_top1")),
                  ("Controller executes", executed_counts(cell)))
        for j, (title, counts) in enumerate(panels):
            draw(axes[i, j], counts, palette, f"{opponent_name[red]} · {title}",
                 cell["post_opening_steps"])
    fig.suptitle("BES / TPG · wins versus Controller execution\\n"
                 "100-step official full-validation cells · fixed opening excluded")
    save_figure(fig, "tpg-wins-vs-execution")

    fig, axes = plt.subplots(2, 2, figsize=(15, 10))
    for i, red in enumerate(RED[:2]):
        for j, arm in enumerate(AGENTS):
            cell = out[arm]["cells"][f"100-{red}"]
            draw(axes[i, j], executed_counts(cell, detailed=True), semantic_colors,
                 f"{opponent_name[red]} · {agent_name[arm]}", cell["post_opening_steps"], .025)
    fig.suptitle("BES / TPG versus Cardiff / PPO · executed host and response\\n"
                 "100-step official full-validation cells · fixed opening excluded")
    save_figure(fig, "tpg-vs-ppo-semantic-pies")

    fig,axes=plt.subplots(3,4,figsize=(17,11))
    for i,h in enumerate(HORIZONS):
        for j,(red,kind) in enumerate((r,k) for r in RED[:2] for k in ("native_top1","effective_top1")):
            cell=out["bes"]["cells"][f"{h}-{red}"]
            c=Counter()
            for a,n in cell["top1"][kind].items():
                c[response(pair(a))]+=n
            total=sum(c.values())
            if total:
                draw(axes[i,j],c,palette,f"{red} · {h} · {kind.replace('_',' ')}",total)
    fig.suptitle("BES · native TPG and post-repair Top-1 proposals")
    save_figure(fig, "bes-top1")
    rows=[]
    for key in out["bes"]["cells"]:
        b,c=(out[a]["cells"][key] for a in AGENTS)
        rows.append(f"<tr><td>{key}</td><td>{b['mean']:.4f}</td><td>{c['mean']:.4f}</td>"
                    f"<td>{b['cvar10']:.3f}</td><td>{c['cvar10']:.3f}</td></tr>")
    comparison = prior_bes_comparison(manifest, out["bes"], output)
    save(destination/"results.json", dict(protocol=manifest, agents=out,
                                         prior_bes_comparison=comparison))
    labels = (
        ("tpg-wins-vs-execution", "TPG wins vs. Controller execution · 100 steps"),
        ("tpg-vs-ppo-semantic-pies", "TPG vs. PPO executed actions · 100 steps"),
        ("executed-responses", "Executed responses · 30, 50 and 100 steps"),
        ("executed-host-response", "Executed host and response · 30, 50 and 100 steps"),
        ("bes-top1", "BES native and post-repair Top-1 · 30, 50 and 100 steps"),
    )
    plots = "".join(f'<h2>{title}</h2><p><a href="{name}.svg">'
                    f'<img src="{name}.png" alt="{title}"></a></p>' for name, title in labels)
    comparison_html = ""
    if comparison:
        cells = "".join(
            f"<tr><td>{key}</td><td>{row['old_mean']:.4f}</td>"
            f"<td>{row['new_mean']:.4f}</td><td>{row['delta']:+.4f}</td>"
            f"<td>{row['old_worst']:.1f}</td><td>{row['new_worst']:.1f}</td></tr>"
            for key, row in comparison["cells"].items())
        tail_note = ""
        if comparison["meander_100_tail_replacement"]:
            tail = comparison["meander_100_tail_replacement"]
            tail_note = (
                f"<p>Meander at 100 steps had {tail['below_minus100']} episode below −100 "
                f"(worst {tail['worst']:.1f}). Replacing that tail with the remaining-episode mean "
                f"would add {tail['delta_to_total']:.4f} to the BES total. This is a sensitivity calculation.</p>"
            )
        parity_note = ""
        if comparison["archived_action_replay"]:
            replay = comparison["archived_action_replay"].values()
            matched = sum(x["matched_steps"] for x in replay)
            expected = sum(x["expected_steps"] for x in replay)
            parity_note = f"<p>The new BES adapter reproduced {matched:,}/{expected:,} archived actions without simulator interaction.</p>"
        comparison_html = (
            "<h2>Previous BES validation comparison</h2>"
            f"<p>Previous total {comparison['old_total']:.4f}. Current total {comparison['new_total']:.4f}. "
            f"Difference {comparison['delta']:+.4f}. Frozen input hash match: "
            f"{'yes' if comparison['same_policy_inputs'] else 'no'}. "
            "The earlier test set explicit simulator seeds and created a fresh environment for each episode. "
            "The current test follows the official script reset sequence with a Python RNG seed. "
            "These are different sample cohorts.</p>"
            "<table><tr><th>Horizon / opponent</th><th>Previous mean</th><th>Current mean</th>"
            "<th>Change</th><th>Previous worst</th><th>Current worst</th></tr>"
            + cells + "</table>" + tail_note + parity_note
        )
    (destination/"index.html").write_text(
        "<!doctype html><meta charset='utf-8'><title>Complete-agent full validation</title>"
        "<style>body{font:16px system-ui;max-width:1350px;margin:2rem auto;padding:1rem}"
        "img{width:100%}td,th{padding:.45rem .8rem;text-align:right}tr:nth-child(even){background:#f2f3f5}</style>"
        "<h1>BES and Cardiff MainAgent full validation</h1>"
        f"<p>Leaderboard-style total · BES {out['bes']['total']:.4f} · Cardiff {out['cardiff']['total']:.4f}</p>"
        "<p>Official CAGE2 2.1 / Scenario2 / ChallengeWrapper. 1,000 episodes per horizon and opponent. "
        "The fixed opening is included in scores and omitted from action pies. Sleep is included in scores. "
        "BES uses its frozen best full dispatch configuration, including the Meander manual routes. "
        "Cardiff uses its MainAgent with both local 90000 checkpoints. Python seed root 153. "
        "These evaluation streams are not treated as episode pairs. The Meander route catalogue used root 153 in discovery.</p>"
        '<p><a href="tpg-wins-vs-execution.svg">TPG wins vs. execution</a> · '
        '<a href="tpg-vs-ppo-semantic-pies.svg">TPG vs. PPO actions</a> · '
        '<a href="results.json">Scores, dispatch, and provenance</a> · '
        '<a href="action-frequencies.tsv">All action counts</a></p>'
        "<table><tr><th>Horizon / opponent</th><th>BES mean</th><th>Cardiff mean</th>"
        "<th>BES CVaR10</th><th>Cardiff CVaR10</th></tr>"+"".join(rows)+"</table>"+comparison_html+plots,
        encoding="utf-8")
    print(f"REPORT {destination}",flush=True)

if __name__ == "__main__":
    mode=sys.argv[1]
    folder=Path(sys.argv[2]).resolve()
    if mode=="worker":
        worker(sys.argv[3],folder,int(sys.argv[4]))
    elif mode=="plot":
        plot(folder,Path(sys.argv[3]))
    elif mode=="run":
        master(folder)
    else:
        raise ValueError(mode)

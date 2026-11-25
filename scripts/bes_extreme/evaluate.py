"""Official root evaluation and graph compilation for the extreme optimizer."""
from collections import Counter
import csv
import hashlib
import importlib.util
import inspect
import json
import os
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
RANKED_GRAPH = HERE.parent / "tpg_compilation/ranked-graph.lisp"
ROLES = ("router", "b_line", "meander")
HOSTS = ("Defender", "Enterprise0", "Enterprise1", "Enterprise2", "Op_Server0",
         "User0", "User1", "User2", "User3", "User4")
SUPPORT = ("standalone-runtime.lisp", "00-post-opening-router.lisp", "01-expert-dispatch.lisp")
EVALUATION_FILES = ("results.json", "episodes.tsv", "actions.tsv")
HORIZONS = (30, 50, 100)
REDS = {"B_lineAgent":"bline", "RedMeanderAgent":"meander", "SleepAgent":"sleep"}
STEPS_PER_CELL_SET = len(REDS) * sum(HORIZONS)


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def save(path, data):
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(data, indent=2, sort_keys=True, allow_nan=False) + "\n", encoding="utf-8")
    part.replace(path)


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def lisp_string(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def table_form(table):
    return "(" + " ".join("(" + " ".join(map(str, table[host])) + ")" for host in HOSTS) + ")\n"


def validate_table(table):
    if not isinstance(table,dict) or set(table) != set(HOSTS):
        raise ValueError("Expected one ordered Decoy option list per Controller host")
    for host, options in table.items():
        if (not isinstance(options,list) or any(type(n) is not int or not 0<=n<8 for n in options)
                or len(set(options)) != len(options)):
            raise ValueError(f"Invalid Decoy option list for {host}")


def bundle_config(bundle):
    config = read(bundle/"policy.json")
    validate_table(config["table"])
    if config["fixed_opening"] != [51,116,55] or config["decoy_resolution"] != "ranked-decoy-hosts":
        raise ValueError("This mode requires the fixed opening and ranked-host Controller protocol")
    if sha(bundle/"code/controller.lisp") != config["controller_sha256"]:
        raise ValueError("Controller hash differs from the bundle manifest")
    assets = config["input_sha256"]
    if set(assets) != set(ROLES):
        raise ValueError("Expected router, B-line and Meander checkpoint inputs")
    for item in assets.values():
        name = item["file"]
        if not name or Path(name).name != name or sha(bundle/"inputs"/name) != item["sha256"]:
            raise ValueError(f"Invalid or changed checkpoint: {name}")
    return config


def code_hashes(bundle):
    files = sorted(p for p in (bundle/"code").rglob("*")
                   if p.is_file() and p.suffix in (".py",".lisp",".asd",".ini"))
    files.extend(bundle/"support"/f for f in SUPPORT)
    # Runtime lives with BES. These hashes also invalidate incompatible resumes.
    files.extend(sorted(HERE.glob("*.py")))
    files.extend((HERE/"runtime.lisp", RANKED_GRAPH))
    return {str(f.relative_to(bundle)) if f.is_relative_to(bundle) else f"mode/{f.name}":sha(f)
            for f in files}


def evaluator(config):
    from CybORG import CYBORG_VERSION, CybORG
    directory = Path(inspect.getfile(CybORG)).resolve().parent
    official = directory/"Evaluation/evaluation.py"
    if CYBORG_VERSION != config["version"] or sha(official) != config["official_script_sha256"]:
        raise ValueError("Installed CybORG version or official evaluation script differs from the bundle")
    fingerprint = hashlib.sha256()
    for path in sorted(directory.rglob("*")):
        if path.is_file() and path.suffix in (".py",".yaml",".yml"):
            fingerprint.update(str(path.relative_to(directory)).encode() + b"\0")
            fingerprint.update(bytes.fromhex(sha(path)))
    return official, fingerprint.hexdigest()


def lisp_dependencies(bundle):
    explicit = os.environ.get("BES_ASDF_DEPENDENCIES")
    trees = ([Path(explicit)] if explicit else [Path.home()/"quicklisp/local-projects",
                                                Path.home()/"quicklisp/dists/quicklisp/software"])
    paths = " ".join(f"(:tree {lisp_string(str(p) + '/')})" for p in trees if p.is_dir())
    return {**os.environ,"CL_SOURCE_REGISTRY":
            f'(:source-registry (:directory {lisp_string(str(bundle/"code")+"/")}) {paths} :ignore-inherited-configuration)'}


def compile_candidate(bundle, source, evidence, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    request = output.with_suffix(".sexp")
    role = {"bline":":b-line","meander":":meander"}[evidence["route"]]
    pairs = evidence["ranking"].split(",")
    if len(pairs)!=8 or any(not re.fullmatch(r"(?:[1-57-9]|10):[0-3]", pair) for pair in pairs):
        # The nine supported targets are 1 through 5 and 7 through 10.
        raise ValueError("Expected eight legal Semantic-36 pairs in the nominated ranking")
    ranking = " ".join("(" + pair.replace(":", " ") + ")" for pair in pairs)
    request.write_text(f'({role} {lisp_string(evidence["observation"])} ({ranking}))\n',encoding="utf-8")
    args = ["sbcl","--noinform","--non-interactive","--eval","(require :asdf)",
            "--eval","(asdf:load-system :cl-tpg)"]
    for path in [*(bundle/"support"/f for f in SUPPORT), RANKED_GRAPH, HERE/"runtime.lisp"]:
        args += ["--load",str(path)]
    # An interrupted Lisp write must never be mistaken for a verified checkpoint.
    pending = output.with_suffix(".incomplete")
    if pending.exists():
        pending.unlink()
    args += ["--eval",f"(cl-tpg::extreme-compile-ranked-edit {lisp_string(source)} "
                      f"{lisp_string(request)} {lisp_string(pending)})"]
    log = output.with_suffix(".log")
    with log.open("w",encoding="utf-8") as stream:
        status = subprocess.run(args,cwd=bundle/"code",env=lisp_dependencies(bundle),
                                stdout=stream,stderr=subprocess.STDOUT).returncode
    if status:
        raise RuntimeError(f"Ranked graph compilation failed. See {log}")
    if not pending.exists():
        if "EXTREME_SKIP " not in log.read_text(encoding="utf-8"):
            raise RuntimeError(f"No compilation result. See {log}")
        return False
    pending.replace(output)
    return True


def rank_nominations(actions, contexts):
    reward_lost = Counter()
    exposures = Counter()
    with actions.open(newline="",encoding="utf-8") as action_rows, \
         contexts.open(encoding="utf-8") as nominations:
        for row, line in zip(csv.DictReader(action_rows,delimiter="\t"), nominations,strict=True):
            route, actual, raw, ranking = line.rstrip("\n").split("\t")
            if row["route"]!=route or row["concrete"]!=actual:
                raise RuntimeError("Archived nominations and official action trace are out of sync")
            if raw=="-":
                continue
            key = (route, raw, ranking)
            exposures[key]+=1
            reward_lost[key]+=max(0.0,-float(row["reward"]))
    return [dict(route=route,observation=raw,ranking=rank,loss=reward_lost[key],observations=exposures[key])
            for key in sorted(exposures,key=lambda k:(-reward_lost[k],-exposures[k],k))
            for route,raw,rank in [key]]


def worker(request_path):
    spec = read(request_path)
    bundle, output = Path(spec["bundle"]), Path(spec["output"])
    config = bundle_config(bundle)
    validate_table(spec["table"])
    official, environment_hash = evaluator(config)
    if environment_hash != spec["environment_sha256"]:
        raise ValueError("Simulator sources changed since this search was configured")
    loader = importlib.util.spec_from_file_location(
        "bes_frozen_official_evaluation",bundle/"code/scripts/full_agent_validation.py")
    module = importlib.util.module_from_spec(loader)
    loader.loader.exec_module(module)
    module.VENV = Path(sys.prefix)
    schedule = request_path.with_suffix(".orders")
    schedule.write_text(table_form(spec["table"]),encoding="utf-8")
    os.environ["BES_EXTREME_ORDERS"] = str(schedule)
    os.environ["BES_EXTREME_TRACE"] = "1" if spec["nominate"] else "0"
    expected = {k:sha(p) for k,p in spec["graphs"].items()}
    if expected!=spec["graph_sha256"]:
        raise ValueError("Candidate graph differs from its evaluation request")
    versions = [*(bundle/"support"/name for name in SUPPORT), RANKED_GRAPH, HERE/"runtime.lisp"]
    module.spec=lambda **_: {
        "official_source":str(official),"official_script_sha256":config["official_script_sha256"],
        "cyborg_commit":config["cyborg_commit"],"version":config["version"],"seed_root":spec["root"],
        "reset_protocol":"official continuous ChallengeWrapper.reset",
        "episodes_per_cell":spec["episodes"],"native_controller_table":spec["table"],
        "controller_sha256":config["controller_sha256"],
        "bes_inputs":{k:{"path":p,"sha256":expected[k]} for k,p in spec["graphs"].items()},
        "bes_code":{str(source):sha(source) for source in versions},
    }
    base = module.BESAgent
    context_file = request_path.with_suffix(".contexts.tsv")

    class TraceAgent(base):
        def get_action(self, obs, action_space):
            raw = "".join(str(int(x)) for x in obs)
            concrete,route,top,effective,context,ranking = self.send("obs "+raw).split()
            self.info = module.LABELS[route],top,effective
            if log:
                log.write(f"{self.info[0]}\t{concrete}\t{context}\t{ranking}\n")
            return int(concrete)

    module.BESAgent=TraceAgent
    log = context_file.open("w",encoding="utf-8") if spec["nominate"] else None
    try:
        module.worker("bes",output,spec["episodes"],seed_root=spec["root"])
    finally:
        if log:
            log.close()
    result = read(output/"results.json")
    assert result["steps"]==STEPS_PER_CELL_SET*spec["episodes"]
    for horizon in HORIZONS:
        for red, route in REDS.items():
            cell = result["cells"][f"{horizon}-{red}"]
            if cell["routes"] != {route: spec["episodes"]}:
                raise RuntimeError(f"Unexpected opponent routes in {horizon}-{red}: {cell['routes']}")
    files = EVALUATION_FILES
    if spec["nominate"]:
        save(output/"nominees.json",rank_nominations(output/"actions.tsv",context_file))
        files += ("nominees.json",)
    save(output/"complete.json",{"request":spec,"files_sha256":{name:sha(output/name) for name in files}})


if __name__=="__main__":
    worker(Path(sys.argv[1]).resolve())

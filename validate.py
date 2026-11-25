"""Evaluate a frozen native Controller and its three program graphs."""
import argparse
import hashlib
import inspect
from pathlib import Path
import json
import os
import subprocess
import sys

SUPPORT = ("standalone-runtime","00-post-opening-router","01-expert-dispatch","09-full-validation-agent")

def read(path):
    return json.loads(path.read_text(encoding="utf-8"))

def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream,"sha256").hexdigest()

def verify_scheduler(policy):
    cfg = read(policy/"policy.json")
    deps = os.environ["BES_ASDF_DEPENDENCIES"]
    env = dict(os.environ, CL_SOURCE_REGISTRY=(
        f'(:source-registry (:directory "{policy}/code/") (:tree "{deps}/") :ignore-inherited-configuration)'
    ))
    orders = "(" + " ".join("(" + " ".join(map(str,v)) + ")" for v in cfg["table"].values()) + ")"
    term = """(in-package :cl-tpg)"""
    check = f"""(dolist (profile '(:bline-cardiff-global :meander-cardiff-global))
      (let* ((controller (make-cage2-controller :decoy-order-profile profile))
             (schedule (cage2-controller-decoy-schedule controller)))
        (assert (eq *cage2-decoy-resolution* :ranked-decoy-hosts))
        (loop for host from 1 for options in '{orders}
              do (assert (equal options (loop for (h o) in schedule when (= host h) collect o))))))"""
    subprocess.run(["sbcl","--noinform","--non-interactive","--eval","(require :asdf)",
                    "--eval","(asdf:load-system :cl-tpg)","--eval",term,"--eval",check],
                   cwd=policy/"code", env=env, check=True)
    print(f'SCHEDULER_PASS {cfg["id"]}', flush=True)

def evaluate(policy, destination, seed, count):
    cfg = read(policy/"policy.json")
    sys.path.insert(0,str(policy/"code/scripts"))
    import full_agent_validation as v
    from CybORG import CYBORG_VERSION, CybORG

    official = Path(inspect.getfile(CybORG)).resolve().parent/"Evaluation/evaluation.py"
    assert sha(official) == cfg["official_script_sha256"] and CYBORG_VERSION == cfg["version"]
    assert sha(policy/"code/controller.lisp") == cfg["controller_sha256"]
    graphs = {}
    for name,item in cfg["input_sha256"].items():
        path = policy/"inputs"/item["file"]
        assert sha(path) == item["sha256"], name
        graphs[name] = {"path":str(path),"sha256":item["sha256"]}
    scripts = [policy/"support"/f"{name}.lisp" for name in SUPPORT]
    v.spec = lambda **_: dict(
        official_source=str(official), official_script_sha256=cfg["official_script_sha256"],
        cyborg_commit=cfg["cyborg_commit"], version=CYBORG_VERSION, seed_root=seed,
        reset_protocol="official continuous ChallengeWrapper.reset", episodes_per_cell=count,
        bes_inputs=graphs, bes_code={str(p):sha(p) for p in scripts},
        controller_sha256=cfg["controller_sha256"], decoy_host_resolution=cfg["decoy_resolution"],
        native_controller_table=cfg["table"], external_bline_guard=False,
        external_meander_route_table=False, fixed_opening=cfg["fixed_opening"])
    v.worker("bes",destination,count,seed_root=seed)
    result = read(destination/"results.json")
    assert result["steps"] == 540*count and len(result["cells"]) == 9
    assert all(cell["episodes"] == count for cell in result["cells"].values())
    assert all(result["cells"][f"{h}-SleepAgent"]["mean"] == 0 for h in (30,50,100))

if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination",type=Path,nargs="?")
    parser.add_argument("--policy",type=Path,default=Path(__file__).resolve().parent)
    parser.add_argument("--verify-scheduler",action="store_true")
    parser.add_argument("--seed",type=int,default=153)
    parser.add_argument("--episodes",type=int,default=1000)
    args=parser.parse_args()
    if args.verify_scheduler:
        verify_scheduler(args.policy.resolve())
    else:
        if args.destination is None:
            parser.error("destination is required for evaluation")
        evaluate(args.policy.resolve(),args.destination.resolve(),args.seed,args.episodes)

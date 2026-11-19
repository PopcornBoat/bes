"""Frozen policy assets and native export; no Torch dependency."""
from pathlib import Path
from continuous_official_search import REPO,run_lisp,sexp
from numeric_policy_tuning import native_call

SOURCE=Path.home()/"bes-artifacts/runtime/continuous-official-search-20261118/b_line/initial.lisp"
ROOT=Path.home()/"bes-artifacts/runtime/torch-terminal-policy-gradient-20261119"

def load_form(body):
    return "(progn (load "+sexp(str(REPO/"scripts/numeric-policy-parameters.lisp"))+") (load "+\
           sexp(str(REPO/"scripts/torch-policy-export.lisp"))+") "+body+")"

def prepare(root=ROOT):
    root.mkdir(parents=True,exist_ok=True)
    inventory=root/"inventory";inventory.mkdir(exist_ok=True)
    if not (inventory/"parameters.tsv").exists():
        run_lisp(native_call("policy-export","b_line",str(SOURCE),str(inventory)+"/"),inventory/"exporter")
    graph=root/"graph.json"
    if not graph.exists():
        run_lisp(load_form("(cl-tpg::torch-policy-export "+sexp(str(SOURCE))+" "+sexp(str(graph))+")"),root/"graph-export")
    return graph,inventory/"parameters.tsv"


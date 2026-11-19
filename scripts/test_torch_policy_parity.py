"""Zero-official-interaction bid, ranking and gradient equivalence checks."""
from pathlib import Path
import json
import math
import sys
import numpy as np
import torch
from continuous_official_search import REPO,read,save,rows,number,run_lisp,sexp,write_sexp
from numeric_policy_tuning import native_call
from torch_terminal_actor import FixedTPG,parameter_table

from torch_policy_assets import ROOT,SOURCE,prepare,load_form

def parity(root=ROOT):
    graph,parameters=prepare(root)
    model=FixedTPG(read(graph),parameter_table(parameters))
    archive=Path.home()/"bes-artifacts/runtime/numeric-policy-tuning-20261119/active/discovery/paired/trace.tsv"
    context_map={}
    for row in rows(archive):
        if row["arm"]=="baseline" and int(row["step"])>=3:
            context_map.setdefault(row["obs"],int(row["mask"]))
    texts=sorted(context_map)[:128]
    output=root/"parity";output.mkdir(exist_ok=True)
    write_sexp(output/"contexts.sexp",texts[:32])
    write_sexp(output/"probes.sexp",[(text,context_map[text]) for text in texts])
    if not (output/"bids.tsv").exists():
        run_lisp(load_form("(cl-tpg::torch-bid-reference "+sexp(str(SOURCE))+" "+
                          sexp(str(output/"contexts.sexp"))+" "+sexp(str(output/"bids.tsv"))+")"),output/"bid-reference")
    if not (output/"rankings.tsv").exists():
        from continuous_official_search import call
        run_lisp(call("probe","b_line",str(SOURCE),str(output/"probes.sexp"),str(output/"rankings.tsv")),output/"rank-reference")
    obs=torch.tensor([[int(c) for c in text] for text in texts[:32]],dtype=torch.float64)
    tensor_bids={}
    with torch.no_grad():
        for ni,node in enumerate(model.nodes):
            values=model.scores(ni,obs)
            for li in range(len(node)):tensor_bids[ni,li]=values[:,li].tolist()
    textindex={t:i for i,t in enumerate(texts[:32])}
    count=0;max_error=0.0
    for r in rows(output/"bids.tsv"):
        ni,li=int(r["node"]),int(r["slot"]);expected=number(r["bid"]);i=textindex[r["obs"]]
        fast=model.fast[ni,li]([int(c) for c in r["obs"]],model.numeric)
        actual=tensor_bids[ni,li][i]
        error=max(abs(fast-expected),abs(actual-expected));max_error=max(max_error,error)
        assert error<=1e-9+1e-10*abs(expected),(ni,li,r["obs"],expected,fast,actual)
        count+=1
    rankings=0
    for r in rows(output/"rankings.tsv"):
        actual,_,_=model.ranking([int(c) for c in r["obs"]])
        expected=[tuple(map(int,p.split(":"))) for p in r["top8"].split(";")]
        assert actual==expected,(r["obs"],actual,expected)
        rankings+=1
    # Finite differences on a real terminal program's log-probability.
    node=next(n for n in sorted(model.sample_nodes)
              if any((n,0,ii,1) in model.locations for ii,_ in model.programs[n,0]))
    example=torch.zeros((1,62),dtype=torch.float64)
    target=min(1,len(model.nodes[node])-1)
    objective=model.probability(model.scores(node,example))[0,target].log()
    gradient=torch.autograd.grad(objective,model.x)[0]
    selected=torch.nonzero(gradient.abs()>1e-10).flatten().tolist()[:8]
    assert selected
    errors=[]
    for i in selected:
        step=1e-6
        with torch.no_grad():
            model.x[i]=step
            plus=float(model.probability(model.scores(node,example))[0,target].log())
            model.x[i]=-step
            minus=float(model.probability(model.scores(node,example))[0,target].log())
            model.x[i]=0
        finite=(plus-minus)/(2*step);errors.append(abs(finite-float(gradient[i])))
        assert abs(finite-float(gradient[i]))<1e-6,(finite,float(gradient[i]))
    # Safe zero-division backward: denominator masking must precede division.
    program=[[0,"DIV","OBS",0.0,"CONST",0.0,2]]
    learner=[program,"ATOMIC",[2,0]]
    params={0:dict(id=0,node=0,learner=0,instruction=0,operand=2,value=0.0,unit=0.05,eligible=1,kind="arithmetic-constant")}
    test=FixedTPG([2,[0.0],[[learner]]],params,temperature=0.25)
    safe=test.scores(0,torch.zeros((2,62),dtype=torch.float64))
    assert torch.isfinite(safe).all() and torch.count_nonzero(safe)==0
    safe.sum().backward()
    assert torch.isfinite(test.x.grad).all() and torch.count_nonzero(test.x.grad)==0
    result=dict(bid_comparisons=count,max_bid_error=max_error,rankings=rankings,
                finite_difference_coordinates=len(errors),max_gradient_error=max(errors),
                trainable_parameters=len(model.ids),stochastic_terminal_teams=len(model.sample_nodes),
                new_official_transitions=0)
    save(output/"results.json",result)
    print("PARITY_PASS",json.dumps(result),flush=True)
    return result

if __name__=="__main__":parity()


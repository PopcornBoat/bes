"""Critical probability and gradient semantics; no official interaction."""
from pathlib import Path
import sys
import unittest
import json
import numpy as np
import torch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"scripts"))
from torch_terminal_actor import FixedTPG

def instruction(value):
    return [[0,"ADD","CONST",value,"CONST",0.0,2]]

def toy(shared=False):
    if shared:
        root=[[instruction(1.0),"REFERENCE",1],[instruction(0.0),"REFERENCE",1]]
        leaf=[[instruction(1.0),"ATOMIC",[2,0]],[instruction(0.9),"ATOMIC",[2,1]]]
        graph=[8,[0.0], [root,leaf]]
        node=1
        parameters={0:dict(id=0,node=0,learner=0,instruction=0,operand=1,value=1.,unit=1.,eligible=1)}
    else:
        leaf=[[instruction(1.0),"ATOMIC",[2,0]],[instruction(0.9),"ATOMIC",[2,1]]]
        graph=[8,[0.0],[leaf]]
        node=0;parameters={}
    parameters[1]=dict(id=1,node=node,learner=0,instruction=0,operand=1,value=1.,unit=1.,eligible=1)
    parameters[2]=dict(id=2,node=node,learner=1,instruction=0,operand=1,value=0.9,unit=1.,eligible=1)
    return FixedTPG(graph,parameters),node

class TorchTerminalTests(unittest.TestCase):
    def test_fast_torch_values_match_after_update(self):
        model,node=toy()
        with torch.no_grad():model.x.copy_(torch.tensor([0.12,-0.03],dtype=torch.float64))
        model.sync();obs=torch.zeros((1,62),dtype=torch.float64)
        actual=model.scores(node,obs)[0].tolist()
        expected=[model.fast[node,i]([0.]*62,model.numeric) for i in range(2)]
        self.assertEqual(actual,expected)

    def test_sample_log_probability_matches_recomputed(self):
        model,node=toy(shared=True)
        _,choices,_=model.ranking([0.]*62,np.random.default_rng(9))
        self.assertEqual(len(choices),1)  # Shared-team traversal must not double count.
        records=[dict(obs=[0.]*62,choices=choices)]
        result,_=model.log_probabilities(records)
        self.assertAlmostEqual(float(result.detach()[0]),sum(c["old_logp"] for c in choices),places=12)

    def test_nonterminal_parameters_stay_frozen(self):
        model,node=toy(shared=True)
        self.assertNotIn(0,model.ids)
        self.assertEqual(model.ids,[1,2])

    def test_score_function_increases_rewarded_action_probability(self):
        model,node=toy()
        obs=torch.zeros((1,62),dtype=torch.float64)
        p=model.probability(model.scores(node,obs))[0]
        before=float(p[1].detach())
        rewards=p.new_tensor([0.,1.])
        loss=-(p.detach()*rewards*p.log()).sum()
        gradient=torch.autograd.grad(loss,model.x)[0]
        self.assertGreater(float(gradient[0]),0)
        self.assertLess(float(gradient[1]),0)
        with torch.no_grad():model.x-=0.1*gradient
        after=float(model.probability(model.scores(node,obs))[0,1].detach())
        self.assertGreater(after,before)

    def test_hard_export_semantics_follow_changed_bids(self):
        model,node=toy()
        original=json.dumps(model.nodes)
        self.assertEqual(model.ranking([0.]*62)[0][0],(2,0))
        with torch.no_grad():model.x.copy_(torch.tensor([-0.2,0.2],dtype=torch.float64))
        model.sync()
        self.assertEqual(model.ranking([0.]*62)[0][0],(2,1))
        self.assertEqual(json.dumps(model.nodes),original)

if __name__=="__main__":unittest.main()


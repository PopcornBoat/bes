"""Fixed native TPG bid programs with terminal-only stochastic policy gradients."""
from __future__ import annotations
from collections import defaultdict
import copy
import json
import math
from pathlib import Path
import time
import numpy as np
import torch
from torch import nn

torch.set_num_threads(1)
DTYPE=torch.float64

def div(a,b): return a/b if b!=0 else 0.0
def mod(a,b): return a-float(math.floor(a/b))*b if b!=0 else 0.0
def tangent(a):
    value=math.tan(a)
    return value if abs(value)<=1e4 else 0.0
def exponential(a):return math.exp(a) if a<7 else 1e3
def logarithm(a):return math.log(a) if a>0 else 0.0
def clip(a):return min(1e3,max(-1e3,a))

def effective_indices(program):
    live={0};result=[]
    for i in range(len(program)-1,-1,-1):
        dest,op,t1,v1,t2,v2,arity=program[i]
        if dest not in live:continue
        result.append(i);live.remove(dest)
        if t1=="REG":live.add(int(v1))
        if arity==2 and t2=="REG":live.add(int(v2))
    return list(reversed(result))

def parameter_table(path):
    import csv
    result={}
    with Path(path).open() as stream:
        for row in csv.DictReader(stream,delimiter="\t"):
            record={k:int(row[k]) for k in ("id","node","learner","instruction","operand","eligible")}
            record.update(kind=row["kind"],value=float(row["value"].replace("d","e")),
                          unit=float(row["unit"].replace("d","e")))
            result[record["id"]]=record
    return result

class FixedTPG(nn.Module):
    def __init__(self,graph,parameters,temperature=0.25,epsilon=0.01):
        super().__init__()
        self.nreg,self.ror,self.nodes=graph
        self.parameters_by_id=parameters
        self.temperature=float(temperature);self.epsilon=float(epsilon)
        self.terminal={i for i,node in enumerate(self.nodes) if node and all(l[1]=="ATOMIC" for l in node)}
        selected=sorted(i for i,p in parameters.items() if p["eligible"] and p["node"] in self.terminal)
        self.ids=selected;self.positions={p:i for i,p in enumerate(selected)}
        self.locations={(p["node"],p["learner"],p["instruction"],p["operand"]):self.positions[i]
                        for i,p in parameters.items() if i in self.positions}
        self.register_buffer("initial",torch.tensor([parameters[i]["value"] for i in selected],dtype=DTYPE))
        self.register_buffer("units",torch.tensor([parameters[i]["unit"] for i in selected],dtype=DTYPE))
        self.x=nn.Parameter(torch.zeros(len(selected),dtype=DTYPE))
        self.programs={}
        self.fast={}
        self.sample_nodes={i for i in self.terminal if len(self.nodes[i])>1
                           and any(p["node"]==i for p in (parameters[j] for j in selected))}
        for ni,node in enumerate(self.nodes):
            for li,learner in enumerate(node):
                program=learner[0]
                keep=effective_indices(program)
                self.programs[ni,li]=[(ii,program[ii]) for ii in keep]
                self.fast[ni,li]=self.compile_fast(ni,li,program,keep)
        self.sync()

    def sync(self):
        self.numeric=(self.initial+self.units*self.x).detach().numpy().copy()

    def fast_argument(self,ni,li,ii,operand,kind,value):
        key=(ni,li,ii,operand)
        if key in self.locations:return f"float(p[{self.locations[key]}])"
        if kind=="CONST":return repr(float(value))
        if kind=="ROR":return repr(float(self.ror[int(value)]))
        if kind=="OBS":return f"o[{int(value)}]"
        if kind=="REG":return f"r{int(value)}"
        raise ValueError(kind)

    def compile_fast(self,ni,li,program,keep):
        code=["def evaluate(o,p):","    "+ " = ".join(f"r{i}" for i in range(self.nreg))+" = 0.0"]
        for ii in keep:
            dest,op,t1,v1,t2,v2,arity=program[ii]
            a=self.fast_argument(ni,li,ii,1,t1,v1)
            b=self.fast_argument(ni,li,ii,2,t2,v2)
            if op in ("ADD","SUB","MUL"):
                expression=f"({a})"+{"ADD":"+","SUB":"-","MUL":"*"}[op]+f"({b})"
            elif op=="EQ":expression=f"(1.0 if ({a}) == ({b}) else 0.0)"
            elif op=="DIV":expression=f"div({a},{b})"
            elif op=="MOD":expression=f"mod({a},{b})"
            elif op=="MAX":expression=f"max({a},{b})"
            elif op in ("SIN","COS"):expression=f"math.{op.lower()}({a})"
            elif op=="TAN":expression=f"tangent({a})"
            elif op=="EXP":expression=f"exponential({a})"
            elif op=="LOG":expression=f"logarithm({a})"
            else:raise ValueError(op)
            code.append(f"    r{dest} = clip({expression})")
        code.append("    return float(r0)")
        namespace=dict(div=div,mod=mod,clip=clip,max=max,math=math,tangent=tangent,
                       exponential=exponential,logarithm=logarithm)
        exec("\n".join(code),namespace)
        return namespace["evaluate"]

    def torch_argument(self,ni,li,ii,operand,kind,value,obs,registers):
        key=(ni,li,ii,operand)
        if key in self.locations:
            k=self.locations[key]
            return self.initial[k]+self.units[k]*self.x[k]
        if kind=="CONST":return obs.new_tensor(float(value))
        if kind=="ROR":return obs.new_tensor(float(self.ror[int(value)]))
        if kind=="OBS":return obs[:,int(value)]
        if kind=="REG":return registers[int(value)]
        raise ValueError(kind)

    def torch_program(self,ni,li,obs):
        registers=[obs.new_zeros(len(obs)) for _ in range(self.nreg)]
        for ii,ins in self.programs[ni,li]:
            dest,op,t1,v1,t2,v2,arity=ins
            a=self.torch_argument(ni,li,ii,1,t1,v1,obs,registers)
            b=self.torch_argument(ni,li,ii,2,t2,v2,obs,registers)
            if op=="ADD":value=a+b
            elif op=="SUB":value=a-b
            elif op=="MUL":value=a*b
            elif op in ("DIV","MOD"):
                safe=torch.where(b!=0,b,torch.ones_like(b))
                value=a/safe if op=="DIV" else a-torch.floor(a/safe)*safe
                value=torch.where(b!=0,value,torch.zeros_like(value))
            elif op=="EQ":value=(a==b).to(DTYPE)
            elif op=="MAX":value=torch.maximum(a,b)
            elif op=="SIN":value=torch.sin(a)
            elif op=="COS":value=torch.cos(a)
            elif op=="TAN":
                value=torch.tan(a);value=torch.where(value.abs()>1e4,torch.zeros_like(value),value)
            elif op=="EXP":value=torch.where(a<7,torch.exp(torch.clamp(a,max=7)),torch.ones_like(a)*1e3)
            elif op=="LOG":value=torch.where(a>0,torch.log(torch.where(a>0,a,torch.ones_like(a))),torch.zeros_like(a))
            else:raise ValueError(op)
            registers[dest]=torch.clamp(value,min=-1e3,max=1e3)
        return registers[0].expand(len(obs))

    def scores(self,node,obs):
        return torch.stack([self.torch_program(node,li,obs) for li in range(len(self.nodes[node]))],dim=1)

    def probability(self,scores):
        return (1-self.epsilon)*torch.softmax(scores/self.temperature,dim=1)+self.epsilon/scores.shape[1]

    def ranking(self,observation,rng=None):
        obs=list(map(float,observation))
        if len(obs)!=62:raise ValueError("Policy inputs must remain 62D")
        cache={};choices=[];pairs=[];seen=set();preferred=[]
        def ordered(node):
            if node not in cache:
                scores=np.array([self.fast[node,li](obs,self.numeric) for li in range(len(self.nodes[node]))])
                if not np.isfinite(scores).all():raise FloatingPointError("Nonfinite bid")
                order=sorted(range(len(scores)),key=lambda i:(-scores[i],i))
                if rng is not None and node in self.sample_nodes:
                    logits=(scores-scores.max())/self.temperature
                    probabilities=np.exp(logits);probabilities/=probabilities.sum()
                    probabilities=(1-self.epsilon)*probabilities+self.epsilon/len(probabilities)
                    chosen=int(rng.choice(len(order),p=probabilities))
                    order=[chosen]+[i for i in order if i!=chosen]
                    choices.append(dict(node=node,slot=chosen,old_logp=float(math.log(probabilities[chosen]))))
                cache[node]=order
            return cache[node]
        def visit(node,visited,depth,is_preferred):
            if len(pairs)>=8:return
            if depth>=128 or node in visited:raise ValueError("Invalid frozen traversal")
            if is_preferred:preferred.append(node)
            for rank,slot in enumerate(ordered(node)):
                learner=self.nodes[node][slot]
                if learner[1]=="ATOMIC":
                    pair=tuple(map(int,learner[2]))
                    if pair not in seen:seen.add(pair);pairs.append(pair)
                else:
                    visit(int(learner[2]),visited+(node,),depth+1,is_preferred and rank==0)
                if len(pairs)>=8:break
        visit(0,(),0,True)
        return pairs,choices,preferred

    def log_probabilities(self,records):
        length=len(records)
        result=self.x.new_zeros(length);entropy=self.x.new_zeros(length)
        groups=defaultdict(list)
        for i,record in enumerate(records):
            for choice in record["choices"]:groups[choice["node"]].append((i,choice["slot"]))
        for node,items in groups.items():
            indices=torch.tensor([i for i,_ in items],dtype=torch.long)
            observations=torch.tensor([records[i]["obs"] for i,_ in items],dtype=DTYPE)
            selected=torch.tensor([s for _,s in items],dtype=torch.long)
            probabilities=self.probability(self.scores(node,observations))
            logp=probabilities.gather(1,selected[:,None]).squeeze(1).log()
            result=result.index_add(0,indices,logp)
            entropy=entropy.index_add(0,indices,-(probabilities*probabilities.log()).sum(1))
        return result,entropy

class Trainer:
    def __init__(self,graph,parameters,output,mode,seed,temperature=0.25,epsilon=0.01):
        torch.manual_seed(int(seed))
        self.model=FixedTPG(graph,parameters,temperature,epsilon)
        self.value=nn.Sequential(nn.Linear(62,64),nn.Tanh(),nn.Linear(64,1)).to(dtype=DTYPE)
        self.actor_optimizer=torch.optim.Adam([self.model.x],lr=0.02)
        self.value_optimizer=torch.optim.Adam(self.value.parameters(),lr=0.001)
        self.mode=mode;self.output=Path(output);self.output.mkdir(parents=True,exist_ok=True)
        self.warm=[];self.batch=[];self.generation=0;self.history=[]
        self.trace=(self.output/"torch-trajectories.jsonl").open("a")
        self.episodes=(self.output/"episodes.jsonl").open("a")
        self.initial_sha=None
    def begin(self,seed,phase,choice_seed):
        self.seed=int(seed);self.phase=phase;self.rows=[];self.pending=None
        self.rng=np.random.default_rng(int(choice_seed))
    def act(self,obs,mask):
        observation=list(map(float,obs))
        stochastic=self.phase=="training"
        ranking,choices,path=self.model.ranking(observation,self.rng if stochastic else None)
        self.pending=dict(obs=observation,mask=str(mask),ranking=ranking,choices=choices,path=path)
        return ranking
    def opening(self,obs,mask,ranking):
        self.pending=dict(obs=list(map(float,obs)),mask=str(mask),ranking=[list(map(int,p)) for p in ranking],choices=[],path=[])
    def feedback(self,reward,target,response,concrete,host):
        if self.pending is None:raise RuntimeError("Feedback without a proposal")
        row=dict(self.pending,reward=float(reward),executed=(int(target),int(response)),
                 concrete=int(concrete),host=json.loads(host))
        self.rows.append(row);self.pending=None
    def finish(self):
        future=0.0
        for row in reversed(self.rows):future+=row["reward"];row["rtg"]=future
        if len(self.rows)!=100:raise RuntimeError("Unexpected episode length")
        for step,row in enumerate(self.rows):
            record=dict(row,step=step,seed=self.seed,phase=self.phase,generation=self.generation)
            record["obs"]="".join(str(int(x)) for x in row["obs"])
            self.trace.write(json.dumps(record,separators=(",",":"))+"\n")
        self.trace.flush()
        record=dict(seed=self.seed,phase=self.phase,generation=self.generation,
                    episode_return=future,choices=sum(len(r["choices"]) for r in self.rows))
        self.episodes.write(json.dumps(record)+"\n");self.episodes.flush()
        if self.phase=="warmup":self.warm.extend(self.rows)
        if self.phase=="training":self.batch.extend(self.rows)
        return future
    def fit_value(self,records,epochs):
        obs=torch.tensor([r["obs"] for r in records],dtype=DTYPE)
        target=torch.tensor([r["rtg"] for r in records],dtype=DTYPE)
        last=0.0
        for _ in range(epochs):
            for start in range(0,len(records),256):
                prediction=self.value(obs[start:start+256]).squeeze(1)
                loss=(prediction-target[start:start+256]).square().mean()
                self.value_optimizer.zero_grad();loss.backward()
                torch.nn.utils.clip_grad_norm_(self.value.parameters(),10.0)
                self.value_optimizer.step();last=float(loss.detach())
        return last
    def warmup(self):
        if self.mode=="learn":self.fit_value(self.warm,20)
        self.warm=[]
    def kl(self,records):
        values=[]
        with torch.no_grad():
            for start in range(0,len(records),32):
                subset=records[start:start+32]
                current,_=self.model.log_probabilities(subset)
                old=current.new_tensor([sum(c["old_logp"] for c in r["choices"]) for r in subset])
                delta=(current-old).clamp(-20,20)
                values.extend((delta.exp()-1-delta).tolist())
        return sum(values)/len(values)
    def update(self):
        records=self.batch;self.batch=[];self.generation+=1
        if self.mode=="frozen":
            assert torch.count_nonzero(self.model.x)==0
            result=dict(update=self.generation,frozen=True,transitions=len(records))
        else:
            observations=torch.tensor([r["obs"] for r in records],dtype=DTYPE)
            returns=torch.tensor([r["rtg"] for r in records],dtype=DTYPE)
            with torch.no_grad():advantage=returns-self.value(observations).squeeze(1)
            advantage=(advantage-advantage.mean())/(advantage.std(unbiased=False)+1e-8)
            # The rollout was collected with unchanged parameters: verify log-probability bookkeeping.
            with torch.no_grad():
                for start in range(0,len(records),32):
                    subset=records[start:start+32]
                    current,_=self.model.log_probabilities(subset)
                    expected=current.new_tensor([sum(c["old_logp"] for c in r["choices"]) for r in subset])
                    assert torch.max((current-expected).abs()).item()<1e-8, "On-policy likelihood mismatch"
            before=self.model.x.detach().clone();optimizer_before=copy.deepcopy(self.actor_optimizer.state_dict())
            self.actor_optimizer.zero_grad()
            objective=0.0
            for start in range(0,len(records),32):
                subset=records[start:start+32]
                logp,entropy=self.model.log_probabilities(subset)
                loss=-(advantage[start:start+32]*logp).sum()/len(records)-0.001*entropy.sum()/len(records)
                if loss.requires_grad:loss.backward()
                objective+=float(loss.detach())
            gradient_norm=float(torch.nn.utils.clip_grad_norm_([self.model.x],1.0))
            assert math.isfinite(gradient_norm), "Nonfinite policy gradient"
            self.actor_optimizer.step()
            with torch.no_grad():self.model.x.clamp_(-0.5,0.5)
            estimated_kl=self.kl(records);accepted=math.isfinite(estimated_kl) and estimated_kl<=0.02
            if not accepted:
                with torch.no_grad():self.model.x.copy_(before)
                self.actor_optimizer.load_state_dict(optimizer_before)
                for group in self.actor_optimizer.param_groups:group["lr"]*=0.5
            self.model.sync()
            value_loss=self.fit_value(records,2)
            result=dict(update=self.generation,frozen=False,transitions=len(records),objective=objective,
                        gradient_norm=gradient_norm,kl=estimated_kl,accepted=accepted,value_loss=value_loss,
                        changed_parameters=int(torch.count_nonzero(self.model.x.detach().abs()>1e-10)),
                        normalized_max=float(self.model.x.detach().abs().max()),
                        step_norm=float(torch.linalg.vector_norm(self.model.x.detach()-before)))
        self.history.append(result)
        with (self.output/"updates.jsonl").open("a") as f:f.write(json.dumps(result)+"\n")
        return json.dumps(result)
    def export(self,path):
        from numeric_policy_tuning import sx
        values=(self.model.initial+self.model.units*self.model.x).detach().tolist()
        patch=[[pid,value] for pid,value,initial in zip(self.model.ids,values,self.model.initial.tolist())
               if value!=initial]
        Path(path).write_text(sx([["candidate",patch]])+"\n")
        torch.save(dict(x=self.model.x.detach(),ids=self.model.ids,critic=self.value.state_dict(),
                        optimizer=self.actor_optimizer.state_dict(),critic_optimizer=self.value_optimizer.state_dict(),history=self.history),str(path)+".pt")
        return len(patch)

_TRIAL=None
def initialize(graph,parameters,output,mode,seed,temperature=0.25,epsilon=0.01):
    global _TRIAL
    _TRIAL=Trainer(json.loads(Path(graph).read_text()),parameter_table(parameters),output,mode,seed,temperature,epsilon)
    print("TORCH_READY",mode,"trainable=",len(_TRIAL.model.ids),"terminal-teams=",len(_TRIAL.model.sample_nodes),flush=True)
def begin(seed,phase,choice_seed):_TRIAL.begin(seed,phase,choice_seed)
def act(obs,mask):return _TRIAL.act(obs,mask)
def opening(obs,mask,ranking):_TRIAL.opening(obs,mask,ranking)
def feedback(reward,target,response,concrete,host):_TRIAL.feedback(reward,target,response,concrete,host)
def finish():return _TRIAL.finish()
def warmup():_TRIAL.warmup()
def update():return _TRIAL.update()
def export(path):return _TRIAL.export(path)


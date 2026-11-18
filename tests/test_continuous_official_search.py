"""Focused accounting and autonomy checks; no official interaction."""
import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
SCRIPT=Path(__file__).resolve().parents[1]/"scripts/continuous_official_search.py"
spec=importlib.util.spec_from_file_location("continuous",SCRIPT)
C=importlib.util.module_from_spec(spec);spec.loader.exec_module(C)

class ContinuousSearchTests(unittest.TestCase):
    def owner(self,opponent="b_line"):
        obj=C.Search.__new__(C.Search)
        obj.args=SimpleNamespace(opponent=opponent,seed=1977)
        obj.state={"streams":{name:0 for name in C.STREAMS}}
        return obj

    def test_seed_streams_disjoint_and_resume_exactly(self):
        used=set()
        for opponent in ("b_line","meander"):
            obj=self.owner(opponent)
            for stream in C.STREAMS:
                first=obj.seeds(stream,100)
                self.assertEqual(len(set(first)),100)
                self.assertTrue(used.isdisjoint(first));used.update(first)
                saved=dict(obj.state["streams"])
                expected=obj.seeds(stream,20)
                obj.state["streams"]=saved
                self.assertEqual(obj.seeds(stream,20),expected)

    def test_scheduler_keeps_profile_and_restore_restriction(self):
        orders=[(2,0,29,1<<8),(8,1,51,1<<57)]
        self.assertEqual(C.resolve([(2,3),(8,2),(3,0)],1<<8,orders),((3,0),4))
        self.assertEqual(C.resolve([(8,2),(3,0)],0,orders),((8,2),142))
        self.assertEqual(C.resolve([(8,3),(2,3),(3,0)],0,orders),((2,3),29))
        self.assertEqual(C.resolve([(8,3),(3,0)],0,orders),((8,3),51))

    def test_normal_states_are_not_excluded_or_called_causal(self):
        obj=self.owner()
        obj.orders=[(target,0,28+C.OFFSETS[target],1<<((target-1)*8)) for target in C.TARGETS]
        data=[dict(step="4",seed=str(seed),obs="0"*62,top8="2:0;3:1",mask="0",pair="2:0",concrete="3")
              for seed in (10,11)]
        catalogue=obj.catalogue(data)
        self.assertTrue(catalogue)
        self.assertTrue(all(c["code"]=="0000" for c in catalogue))
        self.assertEqual({c["target"] for c in catalogue},set(C.TARGETS))
        self.assertTrue(any(tuple(c["alt"])==(8,2) for c in catalogue))
        self.assertTrue(all("displaced" in c for c in catalogue))
        self.assertTrue(all("advantage" not in c for c in catalogue))

    def test_independent_episode_minimum(self):
        obj=self.owner();obj.orders=[]
        row=dict(step="4",seed="10",obs="0"*62,top8="2:0;3:1",mask="0",pair="2:0",concrete="3")
        self.assertEqual(obj.catalogue([row]*100),[])

    def test_negative_filter_preserves_uncertain_candidates(self):
        self.assertTrue(C.permissive(dict(upper=0.8,new_catastrophes=0,mean=-0.2)))
        self.assertFalse(C.permissive(dict(upper=-0.4,new_catastrophes=0)))
        self.assertFalse(C.permissive(dict(upper=10,new_catastrophes=1)))

    def test_strict_final_gate_and_tail_check(self):
        good={str(h):dict(mean=0.2,se=0.05,new_catastrophes=0,cvar_delta=0) for h in (30,50,100)}
        self.assertTrue(C.promotion(good))
        good["100"]["new_catastrophes"]=1
        self.assertFalse(C.promotion(good))

    def test_atomic_state_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/"state.json"
            C.save(path,dict(cycle=7,streams={"promotion":91},incumbent="protected"))
            self.assertEqual(C.read(path)["streams"]["promotion"],91)
            self.assertFalse(path.with_suffix(".json.tmp").exists())

if __name__=="__main__":
    unittest.main()


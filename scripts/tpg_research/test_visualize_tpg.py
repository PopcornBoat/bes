import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from runtime_trace import ActivationTrace
from visualize_tpg import (archive_rows, collect_activity, csv_read, nodes_in, read_graph,
                           task_sets, team_depth, HERE)


def entry(t,l,kind,target):
    return dict(team=t,learner=l,saved_learner=l,kind=kind,target=target,stored="1",kept="1")


class ActivationTests(unittest.TestCase):
    def test_shared_reference_and_controller_paths(self):
        graph=read_graph([
            entry("root","root/0","team","left"),entry("root","root/1","team","right"),
            entry("root","root/2","team","inactive"),
            entry("left","left/0","action","2:3"),entry("left","left/1","team","shared"),
            entry("right","right/0","team","shared"),entry("right","right/1","action","3:0"),
            entry("shared","shared/0","action","3:0"),entry("inactive","inactive/0","action","10:1"),
        ])
        self.assertEqual(team_depth(graph)[1],3)
        self.assertEqual(len([edge for edge in graph["edges"] if edge[1]=="shared"]),2)
        self.assertIn("action/right/1",graph["actions"])
        self.assertIn("action/shared/0",graph["actions"])
        a=("a",0,"p","m")
        b=("b",0,"p","m")
        visits=[("B-line","153","e",a,"4","2:3,3:0",None,None),("Meander","42","e",b,"4","3:0",None,None)]
        reference={0:dict(ranked=["2:3","3:0"], evaluated={"root","left","shared"},
                          paths=[("root/0","left/0"),("root/0","left/1","shared/0")],
                          rank="1",concrete="4",resolution="candidate"),
                   1:dict(ranked=["3:0"],evaluated={"root","right","shared"},
                          paths=[("root/1","right/0","shared/0")],rank="0",concrete="4",resolution="candidate")}
        for row in reference.values():
            for rank,path in enumerate(row["paths"]):
                self.assertTrue(nodes_in(path,rank,graph,row["ranked"])<=row["evaluated"])
        with patch("visualize_tpg.contexts",return_value=iter(visits)):
            activity=collect_activity(graph,[],{a:0,b:1},reference)
        self.assertEqual(task_sets(graph,activity,"selected")["exclusive_regions"],
                         {"B-line":1,"Meander":1,"B-line + Meander":2})
        self.assertEqual(activity["counts"][("B-line","learner","left/0")]["top1"],1)
        self.assertEqual(activity["counts"][("B-line","learner","left/0")]["delivered"],0)
        self.assertEqual(activity["counts"][("B-line","learner","shared/0")]["delivered"],1)
        self.assertEqual(activity["counts"][("Meander","learner","right/1")]["evaluated"],1)
        self.assertEqual(activity["counts"][("Meander","learner","right/1")]["selected"],0)
        self.assertNotIn(("Meander","team","inactive"),activity["counts"])

    def test_opt_in_trace_preserves_archived_action_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/"activation.jsonl.gz"
            args=dict(task="B-line",root=153,episode=4,horizon=100,step=11,
                      observation=[0]*62,decoy_mask=255,native_ranking=[(2,3),(3,0)],
                      actual=4,delivered_rank=1,delivered_pair="3:0")
            with ActivationTrace() as disabled:
                disabled.record(**args)
            self.assertFalse(path.exists())
            with ActivationTrace(path) as writer:
                writer.record(**args)
            data=list(archive_rows({"format":"native","path":str(path),"task":"B-line"}))
            self.assertEqual(data,[(153,"4",100,"0"*62,255,"4","2:3,3:0","1","3:0")])


CHECKPOINT = """(:checkpoint-version 31 :num-observations 62 :terminal-action-format :target-response-36
 :instruction-set-profile :reduced-eq :read-only-register-profile :cage2-categorical-v1
 :team (:id "stored-root" :type :root :learners (
 (:id "external-decoy" :program (:instructions (#(1 :ADD :CONST 1d0 :CONST 2d0 2) #(0 :ADD :CONST 3d0 :CONST 0d0 2)))
 :action (:type :atomic :action (:target-response-36-action :version :cage2-semantic-36-v1 :target 2 :response 3)))
 (:id "external-restore" :program (:instructions (#(0 :ADD :CONST 2d0 :CONST 0d0 2)))
 :action (:type :atomic :action (:target-response-36-action :version :cage2-semantic-36-v1 :target 8 :response 2)))
 (:id "external-analysis" :program (:instructions (#(0 :ADD :CONST 1d0 :CONST 0d0 2)))
 :action (:type :atomic :action (:target-response-36-action :version :cage2-semantic-36-v1 :target 3 :response 0)))
 (:id "duplicate-analysis" :program (:instructions (#(0 :ADD :CONST 0d0 :CONST 0d0 2)))
 :action (:type :atomic :action (:target-response-36-action :version :cage2-semantic-36-v1 :target 3 :response 0)))
 )))"""


class LispIntegrationTests(unittest.TestCase):
    @unittest.skipUnless(os.getenv("CL_SOURCE_REGISTRY"), "set the frozen ASDF source registry")
    def test_checkpoint_reload_and_displaced_top1(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            base, pruned, table, queries, replay=(root/x for x in
                                                ("base.lisp","base-pruned.lisp","table.tsv","queries","replay.tsv"))
            base.write_text(CHECKPOINT)
            queries.write_text(f'(0 "{"0"*62}" {(1<<80)-1} :bline-cardiff-global :ranked-decoy-hosts)\n')
            command=["sbcl","--script",str(HERE/"checkpoint-audit.lisp")]
            subprocess.run(command+["prune",base,pruned,table],check=True)
            subprocess.run(command+["replay",base,pruned,queries,replay],check=True)
            record=list(csv_read(replay))[0]
            self.assertEqual(record["rank"],"2")
            self.assertEqual(record["concrete"],"4")
            self.assertEqual(record["paths"],"stored-root/0;stored-root/1;stored-root/2")
            self.assertEqual(list(csv_read(table))[0]["removed_indices"],"0")
            self.assertEqual(base.read_text(),CHECKPOINT)


if __name__=="__main__":
    unittest.main()

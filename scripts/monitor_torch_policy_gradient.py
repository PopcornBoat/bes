"""Read-only progress monitor; no environment calls."""
import json
from pathlib import Path
import time
ROOT=Path.home()/"bes-artifacts/runtime/torch-terminal-policy-gradient-20261119"
ROOTS=(202611190801,202611190802)
def records(path):
    if not path.exists():return []
    result=[]
    for line in path.read_text().splitlines():
        try:result.append(json.loads(line))
        except json.JSONDecodeError:continue  # Writer may be appending the last record.
    return result

def main():
    previous=None
    while True:
        summary=[];finished=0
        for seedroot in ROOTS:
            for mode in ("learn","frozen"):
                folder=ROOT/"full"/f"root-{seedroot}"/mode
                updates=records(folder/"updates.jsonl")
                episodes=records(folder/"episodes.jsonl")
                done=(folder/"DONE").exists()
                finished+=done
                result=dict(root=seedroot,mode=mode,updates=len(updates),episodes=len(episodes),done=done,
                    hard_checkpoints=len(list(folder.glob("snapshot-*/returns.tsv"))))
                if updates:
                    result.update(accepted=updates[-1].get("accepted"),
                        changed_parameters=updates[-1].get("changed_parameters"),
                        kl=updates[-1].get("kl"))
                training=[e["episode_return"] for e in episodes if e["phase"]=="training"][-8:]
                if training:result["last8_stochastic_return"]=sum(training)/len(training)
                summary.append(result)
        encoded=json.dumps(summary,sort_keys=True)
        if encoded!=previous:
            print(time.strftime("%Y-%m-%d %H:%M:%S"),"PROGRESS",encoded,flush=True);previous=encoded
        if finished==4:
            print("ALL_DONE",flush=True);break
        time.sleep(5)
if __name__=="__main__":main()


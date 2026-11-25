"""Optional append-only recording for a pure graph evaluation driver.

Call record() after a step succeeds, using the policy input and Decoy mask
as they stood before Controller resolution. Disabled writers are no-ops.
"""
from contextlib import AbstractContextManager
import gzip
import json
from pathlib import Path


class ActivationTrace(AbstractContextManager):
    def __init__(self, path=None):
        self.path = Path(path) if path is not None else None
        self.output = None

    def __enter__(self):
        if self.path is not None:
            self.output = (gzip.open(self.path,"xt",encoding="utf-8") if self.path.suffix==".gz"
                           else self.path.open("x",encoding="utf-8"))
        return self

    def record(self, *, task, root, episode, horizon, step, observation,
               decoy_mask, native_ranking, actual, delivered_rank=None, delivered_pair=None,
               route=None):
        if self.output is None:
            return
        observation = tuple(observation)
        if len(observation)!=62 or any(value not in (0,1,2) for value in observation):
            raise ValueError("Expected the recorded 62-dimensional categorical policy input")
        obs = "".join(str(int(value)) for value in observation)
        rank = "-" if delivered_rank is None else str(delivered_rank)
        row = {"schema":"bes-activation-v1","task":task,"root":root,"episode":episode,
               "horizon":horizon,"step":step,"obs":obs,"mask":decoy_mask,
               "ranking":",".join(f"{host}:{response}" for host,response in native_ranking),
               "concrete":actual,"rank":rank,"pair":delivered_pair,"route":route}
        self.output.write(json.dumps(row,separators=(",",":"),allow_nan=False)+"\n")

    def __exit__(self, *exc):
        if self.output is not None:
            self.output.close()
            self.output = None
        return False

"""Direct official action transport for Cardiff-index TPG policies."""
from gymnasium import spaces
from gymnasium.envs.registration import register
import numpy as np

from cage2_bridge.cage2 import Cage2Env


class CardiffEnv(Cage2Env):
    """Expose raw ChallengeWrapper observations and accept concrete action IDs."""

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.action_space = spaces.Discrete(145)
        self.observation_space = spaces.Box(0, 1, shape=(52,), dtype=np.float32)

    def _process_obs(self, obs):
        return np.asarray(obs, dtype=np.float32)

    def step(self, action):
        concrete = self._coerce_index(action)
        if concrete is None or not self.action_space.contains(concrete):
            raise ValueError(f"Invalid official CAGE2 action {action!r}")
        obs, reward, done, info = self.env.step(concrete)
        self.current_step += 1
        info = dict(info or {}, concrete_action=concrete)
        return self._process_obs(obs), float(reward), bool(done), self.current_step >= self.max_steps, info


for red in ("b_line", "meander", "sleep"):
    for steps in (30, 50, 100):
        register(
            id=f"Cage2-cardiff-{red}-{steps}-v0",
            entry_point="cardiff_env:CardiffEnv",
            kwargs={"red_agent": red, "max_steps": steps},
        )

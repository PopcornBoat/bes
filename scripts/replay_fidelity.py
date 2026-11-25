import hashlib
import pickle
import random

import numpy as np

from cage2_bridge.cage2 import Cage2Env


ACTIONS = [(0, 0), (5, 0), (2, 3), (2, 2), (3, 3), (8, 1), (7, 0), (4, 3)]


def digest(value):
    return hashlib.sha256(pickle.dumps(value, protocol=4)).hexdigest()


def safe_digest(value):
    try:
        return digest(value)
    except Exception as exc:
        return f"unavailable: {type(exc).__name__}: {exc}"

def run(env, seed, steps=100):
    observations = []
    rewards = []
    concrete = []
    rng = []
    bridge = []
    state_hashes = []
    snapshot_error = None
    obs, _ = env.reset(seed=seed)
    observations.append(np.asarray(obs).copy())
    rng.append(digest(random.getstate()))
    bridge.append((tuple(env.scan_state.state), tuple(tuple(sorted(x)) for x in env.used_decoys.values())))
    for step in range(steps):
        obs, reward, terminated, truncated, info = env.step(ACTIONS[step % len(ACTIONS)])
        observations.append(np.asarray(obs).copy())
        rewards.append(reward)
        concrete.append(info["concrete_action"])
        rng.append(digest(random.getstate()))
        bridge.append((tuple(env.scan_state.state), tuple(tuple(sorted(x)) for x in env.used_decoys.values())))
        try:
            state_hashes.append(digest(env.cyborg.environment_controller.state))
        except Exception as exc:
            if snapshot_error is None:
                snapshot_error = f"{type(exc).__name__}: {exc}"
            state_hashes.append(None)
        if terminated or truncated:
            break
    return observations, rewards, concrete, rng, bridge, state_hashes, snapshot_error


def compare(a, b):
    obs_a, reward_a, action_a, rng_a, bridge_a, hidden_a, _ = a
    obs_b, reward_b, action_b, rng_b, bridge_b, hidden_b, _ = b
    return {
        "observations": len(obs_a) == len(obs_b) and all(np.array_equal(x, y) for x, y in zip(obs_a, obs_b)),
        "rewards": reward_a == reward_b,
        "concrete_actions": action_a == action_b,
        "python_rng": rng_a == rng_b,
        "bridge_state": bridge_a == bridge_b,
        "pickle_hidden_state": (None not in hidden_a and hidden_a == hidden_b),
        "steps": len(reward_a),
    }


def main():
    for red in ("meander", "b_line"):
        env = Cage2Env(red_agent=red, max_steps=100)
        try:
            for seed in (153, 42, 2026):
                first = run(env, seed)
                first_controller = safe_digest(env.cyborg.environment_controller)
                second = run(env, seed)
                second_controller = safe_digest(env.cyborg.environment_controller)
                separate = Cage2Env(red_agent=red, max_steps=100)
                try:
                    third = run(separate, seed)
                    third_controller = safe_digest(separate.cyborg.environment_controller)
                finally:
                    separate.close()
                print(red, seed, "same-instance", compare(first, second))
                print(red, seed, "new-instance", compare(first, third))
                if first_controller.startswith("unavailable"):
                    print(red, seed, "whole-controller-pickle", first_controller)
                else:
                    print(red, seed, "whole-controller-pickle", first_controller == second_controller, first_controller == third_controller)
                if first[-1]:
                    print("hidden-state-pickle-unavailable:", first[-1])
        finally:
            env.close()


if __name__ == "__main__":
    main()

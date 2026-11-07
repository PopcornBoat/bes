"""Read-only training diagnostics for the official environment before wrapping.

This module returns JSON to the search logger. TPG receives its usual 62 inputs.
No environment state or RNG is modified.
"""
import hashlib
import json
import pickle
import random
from enum import Enum
from ipaddress import IPv4Address, IPv6Address

import gymnasium as gym
import cage2_bridge


def _plain(value):
    if value is None or isinstance(value, (str, bool, int, float)):
        return value
    if isinstance(value, dict):
        return {str(k): _plain(v) for k, v in sorted(value.items(), key=lambda x: str(x[0]))}
    if isinstance(value, (list, tuple)):
        return [_plain(v) for v in value]
    if isinstance(value, set):
        return sorted((_plain(v) for v in value), key=str)
    if isinstance(value, (Enum, IPv4Address, IPv6Address)):
        return str(value)
    # Factory reprs contain allocation addresses that change on replay.
    return {"type": type(value).__module__ + "." + type(value).__qualname__}


def _bes_official_state_digest(env):
    base = env.unwrapped
    state = (base.cyborg.environment_controller.state, random.getstate(),
             tuple(float(x) for x in base.scan_state.state),
             tuple((k, tuple(sorted(v))) for k, v in sorted(base.used_decoys.items())),
             base.current_step)
    return hashlib.sha256(pickle.dumps(state, protocol=4)).hexdigest()


def _bes_privileged_state(env):
    base = env.unwrapped
    controller = base.cyborg.environment_controller
    sessions = {}
    for agent, agent_sessions in sorted(controller.state.sessions.items()):
        sessions[agent] = [
            {key: _plain(getattr(session, key, None))
             for key in ("ident", "host", "username", "active", "parent",
                         "session_type", "sus_pids")}
            for _, session in sorted(agent_sessions.items())
        ]
    actions = {
        agent: {"type": type(action).__name__, "parameters": _plain(action.get_params())}
        for agent, action in sorted(controller.action.items()) if action is not None
    }
    # Read the actual loss components used by the official wrapper.
    if base.current_step == 0:
        actions = {}
    breakdown = (_plain(base.env.get_reward_breakdown("Blue"))
                 if base.current_step > 0 else None)
    red = controller.agent_interfaces["Red"].agent
    hosts = {
        name: {
            "process_count": len(host.processes),
            "decoy_processes": [
                {"pid": process.pid, "name": process.name,
                 "decoy_type": _plain(process.decoy_type)}
                for process in host.processes if bool(process.decoy_type)
            ],
        }
        for name, host in sorted(controller.state.hosts.items())
    }
    payload = {
        "step": base.current_step, "sessions": sessions, "hosts": hosts,
        "actions": actions, "host_penalties": breakdown,
        "red_stage": _plain(getattr(red, "action", None)),
        "red_escalated_hosts": _plain(getattr(red, "escalated_hosts", None)),
        "success": {agent: _plain(observation.data.get("success"))
                    for agent, observation in sorted(controller.observation.items())}
                   if base.current_step > 0 else {},
    }
    return json.dumps(payload, sort_keys=True, allow_nan=False)

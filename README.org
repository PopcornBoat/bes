# BES/TPG Research Extension

## About

This repository is a research-oriented fork of **cl-tpg**, developed for autonomous cyber defence research.

The objective of this project is to extend the engineering capabilities of the original BES/TPG framework without modifying its evolutionary algorithm whenever possible.

Rather than redesigning BES/TPG, this fork focuses on adding practical functionality required for large-scale experimentation, checkpoint management, validation, Gymnasium integration, and cyber defence research while maintaining compatibility with the upstream project whenever possible.

---

## Original Project

This project is based on the original **cl-tpg** repository:

https://github.com/bmcnns/cl-tpg

Please refer to the original project for:

- Installation instructions
- BES/TPG architecture
- Tangled Program Graph (TPG)
- Evolutionary algorithm
- Team and learner representations
- Instruction set
- Online and offline training workflow

This repository intentionally does **not** duplicate the original documentation.

Readers interested in the BES/TPG algorithm itself are encouraged to consult the original repository, while this README focuses exclusively on the engineering extensions introduced in this fork.

---

# Design Philosophy

One of the primary goals of this fork is to preserve the original BES/TPG implementation as much as possible.

The following components remain unchanged from the upstream implementation whenever possible:

- Team representation
- Learner representation
- Program representation
- Mutation operators
- Selection strategy
- Reproduction strategy
- Migration between islands
- Island model
- Evolutionary search workflow

Instead of modifying the evolutionary algorithm itself, new functionality is implemented around the existing framework as auxiliary engineering components.

This approach minimizes divergence from the upstream repository while allowing new research functionality to be integrated cleanly.

---

# Major Extensions

## 1. Automatic Best-Team Checkpoint

A lightweight checkpoint mechanism has been added.

Features include:

- Configurable checkpoint directory
- Configurable checkpoint interval
- Automatic checkpointing during evolution
- Save only the globally best team

Unlike traditional evolutionary checkpoints, this implementation intentionally does **not** save the entire evolutionary population.

---

## 2. Warm-Start Resume Search

Interrupted searches can be resumed without restoring the original population.

The resume workflow is:

```
Random Population
        │
        ▼
Load Saved Best Team
        │
        ▼
Replace First Root Team
        │
        ▼
Evaluate Initial Population
        │
        ▼
Continue Normal Evolution
```

This design preserves evolutionary diversity while allowing previously discovered high-quality policies to seed future searches.

---

## 3. Validation Framework

Training and validation are treated as two completely independent workflows.

Validation loads a previously saved best team and evaluates it without modifying the evolutionary search.

### CAGE2

Two validation modes are currently supported.

**Mode 1**

Single selected Red agent.

Runs:

- 30 steps × 1000 episodes
- 50 steps × 1000 episodes
- 100 steps × 1000 episodes

Results are reported individually, for example:

```
b_line-30
b_line-50
b_line-100
b_line-total
```

The same workflow applies to:

- RedMeanderAgent
- SleepAgent

**Mode 2**

Single selected Red agent.

Runs:

- 100 steps
- User-defined number of episodes

---

### CAGE3

Two validation modes are currently supported.

**Mode 1**

- 500 steps
- 1000 episodes

**Mode 2**

- 500 steps
- User-defined number of episodes

---

## 4. Python Bridge

Online training and validation require a Gymnasium-compatible Python environment.

Rather than modifying the BES/TPG evolutionary engine, this project uses a lightweight **Gymnasium bridge** that connects the Lisp implementation of BES/TPG with Python environments through the standard Gymnasium API.

The bridge is responsible for:

- Registering custom Gymnasium environments
- Wrapping external simulators
- Providing the standard `reset()` / `step()` interface
- Exposing observation and action spaces to BES/TPG

This design keeps Python environments completely independent from the Lisp implementation while allowing new environments to be integrated without modifying the evolutionary core.

The Gymnasium bridge currently used in this project is available here:

https://github.com/PopcornBoat/custom-gym-for-bes

---

## 5. Python Interpreter Management

The framework supports switching between multiple Python environments directly from the Emacs interface.

Typical usage:

```
CAGE2 Python Environment

↓

CAGE3 Python Environment
```

Interpreter selection is:

- Persistent across sessions
- Hot-swappable
- Does not require restarting Lisp

This allows multiple CybORG codebases to coexist without compatibility issues.

---

## 6. Improved Emacs Interface

The Emacs frontend has been extended with several new utilities.

Current functionality includes:

- Configure and start training
- Resume search
- Validation
- Save best team
- Configure Python interpreter
- Automatic path completion
- Dashboard improvements

Interactive TAB completion is supported for:

- Dataset files
- Checkpoint directories
- Saved best teams
- Python interpreters

---

## 7. Dashboard Improvements

Additional runtime statistics have been added to the dashboard.

Current information includes:

- Current best fitness
- Rolling mean fitness
- Generation count
- Total evaluation episodes

These statistics simplify long-running evolutionary experiments.

---

## Notes

The original offline imitation-learning workflow provided by **cl-tpg** is currently preserved.

Research on reward-based offline fitness and additional offline learning strategies is ongoing but has **not** yet been integrated into the main evolutionary workflow.

---

# Current Research Status

Current research focuses on applying BES/TPG to autonomous cyber defence using the CAGE benchmark.

Currently implemented components include:

- Online evolutionary training
- Offline imitation learning (original implementation)
- Automatic best-team checkpointing
- Warm-start resume search
- Validation framework
- CAGE2 integration
- CAGE3 integration
- Gymnasium bridge
- Multiple Python interpreter support
- Enhanced Emacs interface

Future work includes:

- Reward-based offline fitness
- Controller-based CAGE2 evaluation
- Additional cyber defence environments
- Continued synchronization with upstream **cl-tpg**

---

# Acknowledgements

This project would not exist without the excellent work of the original **cl-tpg** authors.

All credit for the BES/TPG framework belongs to the original project.

This repository only extends the framework with additional engineering functionality required for my research while attempting to preserve the original implementation and remain compatible with future upstream development whenever possible.

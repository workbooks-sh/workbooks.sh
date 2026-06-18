# Ether orchestration — two brains, two layers

Two ORTHOGONAL layers, named by OUTCOME (don't conflate):

1. **Ether routing** (`Nexus.Ether.Router`) — PICK ONE lane for a task. Mutually exclusive.
   Outcome: the right single brain handles the whole task.
2. **Ether fusion** (`Nexus.Ether.Fuser`, later) — JOIN BOTH brains on ONE output: diffusion
   drafts a block, AR verifies (speculative decode / DiffuSpec). Outcome: one faster stream.

Axis: "pick one" (routing) vs "join both" (fusion). Build routing first; fusion order is forced
by a constraint (below).

## Routing methods (latency, per 2026 literature)
- **Explicit tags / rule-based** — <1ms. Caller declares `task_type`. WHAT WE HAVE. The right default.
- **Embedding routing** — ~5ms. Match prompt to lane exemplars.
- **Tiny classifier** — 100M encoder, ~50-100ms (negligible vs ~800ms inference). Or use the
  DIFFUSION model itself as the router (one fast denoise → lane label).

## Speculative-diffusion (the deep coupling) — real in 2026
- DiffuSpec (training-free): diffusion multi-token draft in one pass, AR verifies → up to 3x.
- DEER / "Draft with Diffusion, Verify with AR": diffusion drafter + AR verifier.
- Self-Speculative Decoding: diffusion as both drafter+verifier.
Sources: arxiv 2510.02358, 2512.15176, 2510.04147, 2512.20573.

## ⚠️ Constraint that sets build order
Spec-decode needs drafter+verifier in the SAME engine, shared token space, tight loop (verifier
checks draft logits, no network hop). Our two lanes are two HTTP llama-servers → a round-trip per
block kills the win. So:
- HTTP two-lane = perfect for ROUTING, wrong for spec-coupling.
- Spec-coupling needs a co-located single engine (future custom llama.cpp / MLX). Later.

## Build order
- **A — explicit routing (now).** Keep `task_type` explicit. Cheapest, controllable, debuggable.
- **B — concurrency-aware routing (the efficiency lever; small, on what we built).**
  - lane-load-aware dispatch: `route/1` consults `Lane.stat`; if GPU serial queue is deep and the
    task is GPU-preferred-not-required, spill to idle CPU lane.
  - CPU batching across slots while GPU drains one-at-a-time.
  - cost/quality tags: "cheap ok" → CPU; "big brain" → GPU.
- **C — classifier (optional).** Embedding-route or diffusion-as-router behind `route/1`.
- **D — speculative coupling (destination).** Single co-located engine, DiffuSpec-style. Separate build.

Bottom line: explicit routing + a SMART SCHEDULER (B) first. Spec-coupling is a different engine, after.

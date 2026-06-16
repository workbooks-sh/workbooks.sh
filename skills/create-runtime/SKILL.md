---
name: create-runtime
description: Stand up or extend a Workbooks runtime — the single Elixir/BEAM engine that serves workbooks, hosts agents, and executes all compute as WebAssembly on wasmtime. ADVANCED. Enforces a STAGED process that elicits NEEDS before any implementation and refuses to vibe-code engine changes. Use only for runtime/host engine work, adding a new capability behind the Host/Dock surface, or deploying a runtime from scratch. Do NOT use for editing an existing module (use edit-runtime) or for app/toolkit work. NOTE: `work deploy` is the USER tool to run the image — never wire platform-release ops into it.
---

# Create a runtime (staged — anti-vibe-code)

Runtime work is engine work. It is the HOST layer (`runtime/host/**`): fixed at
deploy time, changed only by a new image, shared by every app and agent on the
machine. A mistake here breaks every tenant. So this skill is **staged**: each
stage is a gate. **Do not skip forward.** Writing code before the need is
documented and the design is checked against canon is the failure mode this
skill exists to prevent.

> If you are tweaking an existing module or fixing a tracked bug, STOP — use
> `edit-runtime`. This skill is for new capabilities and standing up a runtime.

## Read first (before Stage 0)

- `skills/workbooks-system/SKILL.md` — what the runtime, Dock, and HOST/LOADED
  boundary ARE. Never invent a mechanism the platform already provides.
- `desktop/docs/platform-model.md` — the one-Host / provider-routing canon
  (epic `wb-lk6`). Summary in `references/host-dock-seam.md`.
- `desktop/ASSESSMENT.md` — **the runtime is canonical**; the desktop frontend
  is re-pointed onto `runtime/host`, never the reverse.

## The stages (each is a gate)

### Stage 0 — ELICIT (no code)
Pull the user's ACTUAL needs and write them down. Do not write code in this
stage. Answer, explicitly:
- **Which capability?** Name it as a namespaced verb (`fs.read`, `agent.run`,
  `chat.stream`, `weave`, …) — the Host vocabulary, not an ad-hoc function.
- **Which provider fulfills it?** `local` (OS/browser), `runtime` (the shared
  server over RCP), or `kernel` (`oql.wasm`). A *target* is a routing config,
  not a code fork.
- **Single-tenant or multi-tenant?** One runtime serves many apps + agents.
- **Does it need network/threads?** Those are host-brokered Dock imports
  granted by policy. BEAM-offload (running a capability on the BEAM instead of
  in WASM) is the **last resort** — only for things WASM genuinely cannot do
  (network, threads). Not a convenience lever.

**GATE:** needs are written down before Stage 1. If the user can't answer
"which provider," you are not ready to design.

### Stage 1 — DESIGN (no code)
Map the needs onto the Host/Dock seam (`host.call` / `host.stream`). Decide how
the **router** dispatches the capability to its **provider**. Check the design
against canon (`references/host-dock-seam.md`):
- Does it reintroduce a **second runtime contract** the UI has to manage?
  → redesign. There is ONE Host.
- Is it trying to compile the OS/Tauri layer to WASM? → no. Swap providers
  behind the Host instead.
- Is the new compute native? → it must run as WASM on wasmtime
  (`references/host-dock-seam.md` "no native exec"). Convert via a compiler
  lane; if it can't convert, that's a finding, not a workaround.

**GATE:** design reviewed against canon and written down.

### Stage 2 — FILE
Open a **bd** epic + sub-issues for the work (platform ledger — see the
`working-with-tasks` skill; `.beads` is local-only, never git). One issue per
shippable unit.

**GATE:** issues exist (`bd show <epic>`).

### Stage 3 — IMPLEMENT
Build the **smallest shippable unit** in `runtime/host/**`. `mix compile` is the
**first gate on every edit** — compile before moving on, every time. Keep the
seam intact: agent and workflow are PEER engines, not toolkit EXEC shapes.

### Stage 4 — VERIFY (tightest tier first)
- `mix test` (~58 files) — or a targeted suite for the module touched.
- `work dev up` / `work dev test` — run it locally; never await CI to learn if it
  works.
- Inspect the live engine: `work rt status`, `work rt get <path>` (e.g. `/health`,
  `/api/workbooks`).
- Prod-parity when needed: `work deploy local` (the SAME OCI image in a krunvm
  container).

### Stage 5 — DEPLOY (users) / RELEASE (platform)
**Do not conflate these.** See `references/release-three-layers.md`.
- **Users** running the image for themselves: `work deploy init | validate |
  apply | status | verify | logs | down`. Their registry, their machine.
- **Platform release** is the THREE-layer model: compilers package = its own
  ghcr package, published **manually**; runtime image = built by **CI** on push
  to main; **never** via `work deploy`. Live-confirm `/health` after.

## References
- `references/host-dock-seam.md` — the one-Host / Dock contract, providers,
  the invariants a runtime change must not break.
- `references/release-three-layers.md` — compilers vs runtime image vs
  `work deploy`; the rule of thumb that keeps them apart.
- `references/deploykit.md` — the user-facing `work deploy` verbs and container
  model.
- `desktop/docs/platform-model.md` — full canon (read the source, not a copy).

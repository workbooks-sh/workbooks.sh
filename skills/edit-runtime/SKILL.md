---
name: edit-runtime
description: Modify the Workbooks runtime/host engine — fix a bug or tweak a capability inside the single Elixir/BEAM engine at `runtime/host/**`. ADVANCED. `mix compile` is the first gate on EVERY edit; `mix test` is the suite. The runtime is canonical — re-point the desktop frontend onto runtime/host, NEVER the reverse. Use for tracked fixes and capability tweaks inside the BEAM engine. For a NEW capability from scratch, use create-runtime's staged flow instead. For app/toolkit work this is the wrong skill.
---

# Edit the runtime

You are changing HOST code — the engine that every app and agent on the machine
runs on. It is fixed at deploy time and changes only through a new image, so
treat each edit as load-bearing: smallest unit, compile immediately, fail loud.

> Adding a capability that doesn't exist yet? Use `create-runtime` — its staged
> ELICIT → DESIGN → FILE flow exists to stop vibe-coded engine changes. This
> skill is for modifying what's already there.

## Read first

- `desktop/ASSESSMENT.md` — **the runtime is canonical.** The desktop frontend
  is the most out-of-date code; re-point it onto `runtime/host`, never edit the
  runtime to match the frontend.
- `references/host-dock-seam.md` — the one-Host / Dock contract you must not
  break while editing.

## Steps

1. **Orient.** Read `desktop/ASSESSMENT.md`, then locate the module under
   `runtime/host/**`. Find the tracked task: `bd ready`, `bd show <id>` (bd is
   the platform ledger — local-only, never git; see `working-with-tasks`).
2. **Claim.** `bd update <id> --claim` before touching code — a peer-claimed
   task is invisible to others.
3. **Edit the smallest unit.** Keep the Host/Dock seam intact: one Host, no
   second runtime contract, capabilities stay host-brokered Dock imports
   granted by policy. Agent and workflow are PEER engines — not toolkit EXEC
   shapes. No native execution added on the runtime path; compute is WASM on
   wasmtime (`references/host-dock-seam.md`).
4. **Compile gate.** `mix compile` IMMEDIATELY after the edit — this is the
   first gate, every time, before anything else.
5. **Test.** `mix test` (or a targeted suite for the module); `work dev test`.
   Re-read your change. Fail loud — don't swallow errors to make a test pass.
6. **Record + push.** `bd close <id>`; a typed, stranger-readable commit;
   `git pull --rebase && git push`. CI rebuilds the runtime image from main
   (`references/release-three-layers.md`). **Live-confirm** `/health` /
   `work rt status` — trust the served engine, not the commit.

## Invariants (do not violate while editing)

- One Host surface; never reintroduce a second runtime contract the UI manages.
- HOST is deploy-fixed; only LOADED artifacts (workbooks, toolkits, agent defs,
  workflow specs, boards) hot-swap on a live engine.
- Two HTTP planes never blend — public is anonymous + GET-only; every write is
  on the bearer-authed control plane.
- Don't wire platform-release ops into `work deploy` — that's the USER tool.

## References
- `references/host-dock-seam.md` — the Host/Dock contract + invariants.
- `references/release-three-layers.md` — what CI rebuilds vs what's manual vs
  what `work deploy` is (so a push doesn't get mistaken for a release).

---
name: workbooks-system
description: The Workbooks platform, for any developer or agent building on it — what a workbook, the runtime, a toolkit, and a workflow are; the WebAssembly-only rules of engagement; bundling/unbundling; publishing; running your own runtime with Deploy Kit; authoring toolkits and agent skills. Use this skill whenever working with workbooks, the work CLI, a workbooks runtime/engine, toolkits, agents on the runtime, or anything involving "bundle", "unbundle", "publish", "deploy", "toolkit", or "WASM" in a Workbooks context — read it BEFORE inventing a mechanism, because the platform almost always already provides the mechanism.
---

# The Workbooks system

Workbooks is an ecosystem for building software, in three layers. Everything
below is organized around them:

1. **Workbooks** — the apps. A workbook is a client package: an entire app
   (data, logic, interface, and — when it computes — an embedded WebAssembly
   kernel) bundled into one HTML artifact. → `references/workbooks.md`
2. **The runtime** — one server (Elixir/BEAM) that serves workbooks, runs
   agents, and executes all compute as WebAssembly. You can run your own:
   that's Deploy Kit. → `references/deploykit.md`
3. **Toolkits** — the authoring system: how capabilities, commands, agent
   skills, and instances get built and extended. → `references/toolkit.md`

## Facts — what things are (and are not)

- A **workbook** is both a document and a program. Its defining mechanic is
  **bundle ⇄ unbundle**: a project of source files compiles INTO the
  artifact, and the artifact unbundles BACK into editable source. Neither
  direction is lossy; the artifact is never the thing you hand-edit.
- The **runtime** is not a per-app server. One runtime propagates many apps
  and agents and runs all their concurrent processes on a single machine.
- A **toolkit** is not a plugin API. To an agent, a toolkit is CLI commands
  on PATH plus org-mode skill files read progressively. Agents have one tool
  worldview — a shell — and capabilities arrive as commands, not as new
  tool-registry entries.
- A **workflow** is not a DSL. A native org outline IS the workflow: TODO
  keywords are states, nesting is sub-workflows, properties are edges and
  gates. The runtime executes the outline; org owns the spec.
- The **Dock** is the membrane between a workbook's WASM and the host:
  capabilities (filesystem, network, time) are host-brokered imports granted
  by policy — never ambient, never inherited.

## Rules of engagement (these are invariants, not preferences)

- **No native code execution on a deployed runtime.** All compute runs as
  WebAssembly on wasmtime. Don't install language toolchains (node, python,
  cargo) into runtime images for agents or build paths; convert the
  capability through a compiler lane instead → `references/toolkit.md`.
- **Two HTTP planes, never blended.** The public content plane is anonymous
  and GET-only (published bytes, public feeds). The control plane is
  bearer-authed and owns every write (deploys, instances, agent ops). Never
  add a write to the public plane.
- **HOST vs LOADED.** Host engine code is fixed at deploy time and changes
  only through a new runtime image. Loaded artifacts — workbooks, toolkits,
  agent definitions, workflow/lifecycle specs, boards — hot-swap on a live
  engine. Self-modifying systems edit LOADED, never HOST.
- **Build inputs never ship in the runnable artifact** unless they are
  WebAssembly or a built bundle. Source lives on the source rail (git);
  the artifact carries outputs.
- **Deploy through the platform** (`work` CLI / Deploy Kit / the control
  plane), not by shelling into machines. → `references/deploykit.md`

## Where to go next

Concept layer (what the pieces ARE) — then the surface layer (every command,
route, spec, env var — by what you're DOING):

| Task | Read |
|---|---|
| author/bundle/unbundle/publish a workbook; the artifact | `references/workbooks.md` |
| run/operate/extend your own runtime; deploy engines; env contract | `references/deploykit.md` |
| build commands, toolkits, agent skills; convert anything to WASM | `references/toolkit.md` |
| find a `work` command by purpose (the whole tree at a glance) | `references/cli/index.md` |
| author/bundle/sign/publish/query a workbook (need→action→output) | `references/cli/workbook.md` |
| stand up / inspect a runtime (`work deploy …`) | `references/cli/deploy.md` |
| discover/build/run/eval toolkits + the compiler lane (`work toolkit …`) | `references/cli/toolkit.md` |
| talk to a running engine, configure vars, dev loop (`work rt/dev/var/desktop`) | `references/cli/engine.md` |
| the two HTTP planes' full route tables + auth ladder | `references/http.md` |
| the org-file specs the runtime executes (agent/workflow/lifecycle/manifest) | `references/org-specs.md` |
| every `WB_*` env var — purpose, default, subsystem | `references/env.md` |

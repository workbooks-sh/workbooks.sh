# Toolkits — building capabilities, instances, and agent skills

A toolkit is how anything gains a capability in Workbooks: a unit of
commands an agent (or workbook) can execute, plus the skills that teach an
agent to use them well. The deployed substrate executes WebAssembly only, so
"shipping a tool" always ends in a WASM artifact — that constraint is the
design, not a limitation to route around.

## The agent's worldview (design for it)

An agent on the runtime has one tool surface: a shell. Capabilities arrive
as commands on PATH; knowledge arrives as org skill files it reads
progressively:

```
wb toolkit list                # what's installed
wb toolkit search <query>      # find a capability
wb toolkit show <id>           # the toolkit's overview skill
wb toolkit show <id> <skill>   # a specific recipe, loaded only when needed
wb toolkit run <id> <task> -- <args>
```

Never design a capability as a bespoke "tool registry" entry or a special
API an agent must be hard-coded to know. If an agent needs it, it's a
command + a skill.

## Converting a capability to WASM (the lanes)

When an agent or workbook needs a CLI, library, or language that isn't
already available, convert it through a compiler lane — all of which run
inside the sandbox themselves:

- **C / Zig** — compile to `wasm32-wasi` with the in-sandbox clang/zig
  toolchains.
- **Rust** — full-std Rust compiles in-sandbox (a bootstrap compiler chain;
  no native cargo on the engine). Crate dependencies resolve through the
  platform's registry lane.
- **JavaScript / TypeScript / npm** — the JS lane resolves and fetches npm
  packages, hoists a node_modules tree, and bundles to a single artifact —
  all under a WASM JS engine with Node-style shims. Pure-JS compilers
  (TypeScript, UI-framework compilers) run inside this lane too: compile
  step first, bundle step after, zero native execution.
- **Anything already WASM/WASI** — register it directly as a command.

Decision rule: if the capability's compiler/toolchain is itself pure code
(JS, C, Rust…), it can run in a lane; if it fundamentally requires a native
OS process, it does not belong on a deployed runtime — broker the capability
through the host as a Dock import instead (a policy-gated host function),
which is the escape valve for things WASM cannot do (raw network listeners,
OS integration).

## Anatomy of a toolkit

```
my-toolkit/
├── manifest.org          # identity, the commands it provides, exec shapes
└── skills/
    ├── overview.org      # what this toolkit is for; the map of its skills
    ├── <task-a>.org      # one recipe per job-to-be-done
    └── <task-b>.org
```

Exec shapes (what a command can be): `command` (a WASM CLI), `component`
(a typed WASM component), `task`, `posix` (a POSIX-style program), `kernel`
(a renderer/kernel-shape module), `federation` (a remote capability). Use
`command` unless you specifically need another shape.

Verify before shipping: `wb toolkit verify <id>` — and treat an unbuilt or
unverifiable command as not shipped.

## Writing skills for agents (the methodology)

Skills use progressive disclosure — the same discipline at three levels:

1. **overview.org** (always cheap to read): what the toolkit does, when to
   reach for it, a table of its skills. An agent should know from this file
   alone whether it's in the right place.
2. **One skill file per job**: imperative recipes with exact commands and
   expected outputs. Include the failure modes the agent will actually hit
   and what they mean — an agent that can interpret an error doesn't loop.
3. **Budgets and boundaries in the skill, not in lore**: if a capability
   costs money or time (an external API, a heavy build), the skill states
   the per-run budget and when NOT to use it.

Write for a reader with zero shared history: no project war stories, no
references to past incidents — state the rule and the why. Skills are
published artifacts; assume they ship to strangers (and to agents running
on runtimes you'll never see).

## Instances and isolation

Toolkit commands execute as isolated WASM instances on one shared engine.
Nesting is host-brokered (a flat forest — no wasm-inside-wasm), and
capabilities flow down by explicit grant, never inheritance. Escalation
tiers exist above instances (OS process, peer node, container) — but
default isolation is strong; reach for higher tiers only with cause.

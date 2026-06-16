
# Capability Matrix

> What actually works today, what is partial, what is north-star, and what is walled — every capability × tier × evidence, grouped by surface. The honesty hub.

- **MATURITY:** ships-today
- **EVIDENCE:** web/learn/.audit/AUDIT.md:7

This is the single honest answer to "what works?". Every row carries a tier and,
for any claim of present-tense capability, a real `file:line` you can open. It is
seeded from the per-claim drift audit ([AUDIT.md](../../learn/.audit/AUDIT.md)), the wall canon
([WALLS.md](../../../runtime/.campaign/WALLS.md)), and the project canon (`CLAUDE.md`). When code and a row disagree,
the code wins and the row is a bug — file it.

## The four tiers

- **ships-today** — verifiable now against a named `file:line`. Most of the engine.
  Carries `:EVIDENCE:`.
- **partial** — the primitive exists, but the feature **as commonly described** is
  composed/scoped/one-way. The audit's #1 over-claim category. Carries
  `:EVIDENCE:` **and** `:CAVEAT:`.
- **north-star** — intended. Code may be a Phase-1 stub or absent. *Never written
  in the present tense.* Carries `:CAVEAT:`.
- **wall** — known-impossible-as-described under the architecture. Maps to one of
  the three walls. Carries `:WALL: bedrock|bridge|forge`.

There is no GA/Beta/Experimental here: Workbooks ships no support SLA, so those
labels would lie. These four are about **truth of the claim**, not a release stage.

## The three walls (for `wall` rows)

| wall | the boundary | escape |
| --- | --- | --- |
| bedrock | guest is sandboxed wasm — no native exec, no JIT | only as a **trusted host service** across the Dock |
| bridge | no browser/JS host for emscripten/wasm-bindgen wasm | headless emscripten host on BEAM (narrow) |
| forge | our in-sandbox compilers can't yet **produce** the wasm | a build — home turf, effort → live capability |

Source: [runtime/.campaign/WALLS.md](../../../runtime/.campaign/WALLS.md) (`WALLS.md:22` bedrock, `:42` bridge, `:89` forge).

# Engine (Nexus runtime)

- **OWNER:** runtime

The Elixir/BEAM runtime — the load-bearing pillar. Most ships-today capability
lives here.

## Sandboxed compute & capability gating

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/policy.ex:29
- **SRC:** runtime/host/policy.ex#profiles

Capabilities don't exist unless granted — importing an ungranted cap fails to
instantiate. Profiles defined in `policy.ex:29` (`minimal/network/posix`; the
fail-closed default is `compute` = `vfs` only).

> **Caution:** The lowest grantable profile `minimal` is **not** "no network, no secrets" — it still grants `secrets` + SSRF-brokered raw sockets (`tcp udp tls`). Choose `compute` for a true no-secrets, no-net sandbox. (Audit correction to `safe-powers`.)

## One reader everywhere — the OQL kernel

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/kernel/src/lib.rs:30
- **SRC:** runtime/kernel/src/lib.rs#parse_headlines

The same kernel parses/lints/tangles org natively and in the browser
(`lib.rs:30` `parse_headlines`, `:53` `tangle_plan`). `tangle` is a read-only
derivation to a typed JSON build plan, no server.

## Tamper-evident run ledger

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/ledger.ex:34
- **SRC:** runtime/host/ledger.ex#seal

Each step's hash folds in the prior hash (hash-chain), then the head is signed
(`ledger.ex:10,34`). Editing any step breaks the chain.

## Agent = loop + shell

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/agent.ex:1
- **SRC:** runtime/host/agent.ex#Agent

The agent is a real module — a loop with a single tool surface (bash over
brokered CLIs). See [what an agent is](../../learn/what-an-agent-is.html).

## Public history feed without login

- **MATURITY:** partial
- **EVIDENCE:** runtime/host/auth.ex:28
- **CAVEAT:** /rcp/changes is NOT in the @public allowlist; it returns 401 on locked/multi-tenant deploys. Only /health and two .well-known routes are public.

The `@public` allowlist is exactly =/health /.well-known/workbooks-runtime
/.well-known/did.json= (`auth.ex:28`). "Anyone can read the history" is true only
on an open single-tenant deploy. (Audit correction to `going-live`.)

# Provenance & identity

- **OWNER:** runtime

## Sealed secrets in the open / encrypt-to-share

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/secret.ex:1
- **SRC:** runtime/host/secret.ex

Secret sealing/escrow is real (`secret.ex`, `secret_broker.ex`, `secrets.ex`).

> **Caution:** The runtime key-store is non-persistent — a restart revokes in-memory keys. (Audit note to `secrets-in-the-open`.)

## Authorship survives a machine wipe

- **MATURITY:** partial
- **EVIDENCE:** runtime/host/git.ex:62
- **CAVEAT:** Only the PRIMARY tenant's DID is seed-persisted (WB_SIGNING_KEY, a Fly secret, git.ex:62-85). Other tenants regenerate their DID on redeploy until BYOD storage ships.

(Audit correction to `carries-its-story`.)

# The portable artifact

- **OWNER:** runtime

## "One .html carries everything (screen + logic + data + history)"

- **MATURITY:** partial
- **EVIDENCE:** runtime/host/bundle.ex:3
- **CAVEAT:** The portable egress unit is a .wbundle ZIP, not a single HTML — it holds the HTML PLUS a separate vfs.sqlite entry (bundle.ex:13,49). History rides as a server-side per-tenant git repo (git.ex), not inside the file.

The most-cited over-claim. The `.html` is the **view**; the shareable **unit** is
`wbundle/1` (`bundle.ex:58`). (Audit: three false claims on `the-one-file` +
`a-disk-that-travels`.)

## "There is no server; what you see is all there is"

- **MATURITY:** partial
- **EVIDENCE:** runtime/host/agent.ex:1
- **CAVEAT:** The static view is server-free, but live behavior routes through the runtime over RCP/HTTP+WS (CLAUDE.md architecture canon). The system IS a runtime server; the file is the portable artifact, not the whole system.

(Audit correction to `the-one-file`. Canon: the runtime is "the main component to
stand on.")

# wbx CLI

- **OWNER:** cli

## The verb spine (`tangle / query / lint`)

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/main.rs:1
- **SRC:** cli/src/main.rs#Subcommand

Native CLI verbs link the kernel directly (no server). The canonical `wb` is the
Elixir escript; `reference/cli.md` is auto-tangled from clap.

## "Every command tells you the next one"

- **MATURITY:** partial
- **EVIDENCE:** cli/src/mode.rs:180
- **CAVEAT:** Only ~7 verbs carry a next-hint (mode.rs:180); most return None.

## "Run the identical command the agent ran, in-sandbox"

- **MATURITY:** partial
- **EVIDENCE:** cli/src/io.rs:163
- **CAVEAT:** In-sandbox engine verbs bail (io.rs:163) until the Dock HTTP broker lands. Full in-sandbox wbx parity is not yet real. (Audit correction to the-one-command.)

## dev split-pane "source on one side, living page on the other"

- **MATURITY:** partial
- **EVIDENCE:** cli/src/dev.rs:1
- **CAVEAT:** dev serves the rendered page with a reload poll; there is no source pane.

# Toolkits & lanes

- **OWNER:** toolkits

## Compilers in WASM (C / Zig / Rust)

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/.campaign/WALLS.md:94
- **SRC:** runtime/.campaign/WALLS.md#forge

C/Zig/Rust compile + run **inside** the sandbox; builds never run as untrusted
native code. Rust threads, rayon-core, wasm SIMD, and C++ exceptions are all
proven (`WALLS.md:94-117`). Recipes in `runtime/compilers/<lang>/`.

## npm / Node-compatible in sandbox

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/.campaign/WALLS.md:81
- **SRC:** runtime/compilers/js

JS npm lane (resolve/fetch/bundle + Node shims) with host-brokered fs+net.

## Toolkit eval (standing bench)

- **MATURITY:** partial
- **EVIDENCE:** runtime/host/toolkits.ex:258
- **CAVEAT:** Real but toolkit-scoped — `wb toolkit eval <id>` runs a bundled suite (toolkits.ex:253,258). There is no standalone evals primitive, and the "couple of minutes / fraction of a cent" cost/speed figures are unbenchmarked. (Audit correction to did-it-do-well.)

# Automation & the living system

- **OWNER:** runtime

## Two-way live kanban (drag a card → the word flips to DONE)

- **MATURITY:** partial
- **EVIDENCE:** runtime/host/toolkits.ex:253
- **CAVEAT:** Board rendering is one-way regen from bd; there is no org-backed drag writer / module that writes a status change back. (Audit correction to plans-that-run.)

## "A schedule self-runs from the bare file"

- **MATURITY:** partial
- **EVIDENCE:** runtime/host/agent.ex:1
- **CAVEAT:** Requires a running keeper/scheduler process; the file alone does nothing. (Audit correction to plans-that-run.)

## Background worker pulls outside data to disk for agents

- **MATURITY:** partial
- **EVIDENCE:** runtime/host/agent.ex:1
- **CAVEAT:** Primitives exist (keeper + host egress) but there is no shipped single-feature path — it is a composed pattern. (Audit correction to the-disk-grows.)

## The autopoet (self-editing living system)

- **MATURITY:** north-star
- **CAVEAT:** autopoet.ex is Phase-1 ONLY — a metacognitive issue backlog: when an agent hits a missing capability it FILES an issue (autopoet.ex:1-11) instead of stalling. The central agent that works the backlog down by editing the declarative config layer is later-phase, not shipped. Brand canon: pitch "software built in workbooks," NEVER "sites that run themselves."

The thesis's emotional peak and the audit's **highest-risk over-claim**. Frame it
honestly. Evidence of the Phase-1 stub: `runtime/host/autopoet.ex:1`.

# Browser (desktop)

- **OWNER:** desktop

## Local org rendering + kernel in the app

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/kernel/src/lib.rs:30
- **SRC:** desktop/src/lib/oql-wasm

The desktop app embeds the OQL kernel (wasmtime) and weaves workbooks locally;
viewing is not gated on a server.

## "The app is itself made of workbooks / no privileged frozen core"

- **MATURITY:** north-star
- **CAVEAT:** The desktop app is a conventional Svelte app today. "The UI becomes a workbook" is the documented north star, not the current state. It is extensible via toolkits now; it is not self-hosting yet. (Audit correction to the-browser.)

# Walls (known-impossible-as-described)

- **OWNER:** runtime

These are not gaps to apologize for — documenting **why** they hold is the
credibility moat.

## Arbitrary native binaries / a JIT that emits native, in-guest

- **MATURITY:** wall
- **WALL:** bedrock

The guest can never generate or run native code at runtime (W^X / no JIT) — that
seal **is** the security boundary (`WALLS.md:22`). The only escape is a *trusted
host service* across the Dock (the broker model); the microVM tier was refused.
Members: V8/Deno/Node-native, JVM, native binaries, GPU compute.

## Vendor-CDN emscripten wasm (DuckDB-wasm, esbuild-wasm, ONNX-web) as-shipped

- **MATURITY:** wall
- **WALL:** bridge

Prebuilt emscripten/wasm-bindgen wasm imports a browser/JS host we don't provide
(`WALLS.md:42,72`). The narrow escape (EmscriptenDock) works only for
**self-compiled** `-sSTANDALONE_WASM` modules. The real path for these is FORGE —
rebuild from source to clean wasi.

## edition-2024 Rust / proc-macros; Go→wasip1; Fortran/OCaml

- **MATURITY:** wall
- **WALL:** forge

Our in-sandbox compilers can't yet **produce** these (`WALLS.md:89-119`). Not
impossible — each is a build. mrustc is frozen at 1.74 (edition-2024 is a parser
ceiling; proc-macros a separate mechanism); a Go→wasip1 toolchain unblocks
esbuild + the Go ecosystem.

# How to read a row

Each capability heading carries a property drawer:

```text
:MATURITY: ships-today | partial | north-star | wall
:EVIDENCE: <path:line>   (required for ships-today / partial)
:CAVEAT:   <one line>    (required for partial / north-star)
:WALL:     bedrock|bridge|forge   (required for wall)
:SRC:      <path#anchor>  (where the truth lives in code)
:END:
```

A `ships-today` or `partial` row whose `:EVIDENCE:` path no longer exists is a
broken claim — the docs drift gate fails the build, so a row cannot silently
out-live its code.

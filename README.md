<div align="center">

<img src=".github/assets/logo.png" width="88" alt="Workbooks logo" />

# Workbooks

**One file for everything. One runtime for anywhere.**

[![License](https://img.shields.io/badge/license-Apache--2.0-3a7afe.svg)](LICENSE)
&nbsp;![Platform](https://img.shields.io/badge/desktop-macOS%20·%20Linux%20·%20Windows-555.svg)
&nbsp;![Stack](https://img.shields.io/badge/built%20with-Elixir%20+%20WebAssembly-6b4fbb.svg)

</div>

A Workbook is one file that holds an entire working app — its code, its data, and its
interface. The Runtime brings that file to life the same way on your laptop, your server,
or the web. You build with agents, you own the result, and it runs on infrastructure you
control.

```mermaid
flowchart LR
    Build["✍️ Write code<br/>you + agents"] --> WB["📄 Workbook<br/>one file = the whole app"]
    WB --> Run["⚙️ Runtime"]
    Run --> Where["💻 Laptop &nbsp; 🖥️ Server &nbsp; 🌐 Web"]

    classDef accent stroke:#e8612a,stroke-width:2px;
    class WB accent
```

## The idea

Workbooks is two parts that fit together — and those two parts are the whole ecosystem.

Think of a Workbook like a PDF: one file you can open, send, or keep — except the file
isn't a document, it's a running app. That works because of two halves:

- **The Workbook** is the *format* — what you build, and what you hand to someone.
- **The Runtime** is the *engine* — what brings the format to life, anywhere.

The file is portable because the engine runs everywhere. The engine matters because the
file is portable. One promise, two halves — here's each.

### The Workbook — the format

You build a Workbook the normal way: writing real code (Svelte, SolidJS, Rust, and more),
tied together with **Org** — a plain-text format (think Markdown's older, more capable
cousin) that keeps writing, structure, and code in one document. The bundler packs all of
it into a single, self-contained `.html` — code, data, and interface in one file. Hand it to
someone and they have the working app, not a link to a service you have to keep alive. And
because it's HTML at the surface, the same Workbook can be many things:

```mermaid
mindmap
  root((A Workbook))
    Document
    Filesystem of docs
    Database
    Single-page app
    Desktop app
    Web page
    Container
```

### The Runtime — the engine

One Runtime runs any Workbook the same way everywhere. It's built on Elixir, so it stays
fast and parallel under load with nothing to babysit, and it runs real code — in several
languages — inside a sandbox, so even untrusted code stays in its box.

It's **multi-tenant from the ground up**, so the same engine that runs your own apps can
serve your whole team and your clients too — each tenant isolated, with its own data and
identity. Build something for yourself, then open it up to everyone else without standing
up new infrastructure. Run it yourself for free with your own keys, or let us run it in the
cloud when you'd rather not — the managed option is a convenience, never a gate.

```mermaid
flowchart LR
    WB["📄 Your Workbooks"] --> RT["⚙️ One Runtime<br/>multi-tenant · sandbox · agents"]
    RT --> You["👤 You"]
    RT --> Team["👥 Your team"]
    RT --> Clients["🧑‍💼 Your clients"]

    classDef start fill:#28c84018,stroke:#28c840,stroke-width:1.5px;
    class You start
```

## Why it's built this way

**Cheaper to run, on purpose.** Workbooks doesn't rent you space in a cloud vendor's
runtime and bill you per request. You run it on infrastructure you control — so your cost
is your own machine, not a meter that climbs with every bit of traffic.

**Built for agents and people to build together.** Agents and humans work in the same
format and share the same data. Authoring, testing, shipping, and publishing are all
designed to be things an agent can do — not just a human.

**The structure is the memory.** There's no bolt-on "memory" system. Because a Workbook
keeps code and context together in one readable format, an agent gets the context it needs
from the file itself — which keeps it on track instead of drifting.

**Opinionated where it counts.** The Runtime makes a few decisions for you so everything
speaks the same language and connects to the same data. That's what makes a pile of
separate tools behave like one system.

## How it works

**An agent builds it.** You describe what you want; the agent works in a loop — taking one
step at a time with a small set of tools — and records every step so you can see exactly
what it did.

```mermaid
flowchart LR
    You["👤 You<br/>describe the app"] --> Agent["🤖 Agent"]
    Agent <-->|"step ⇄ result · repeats until done"| Tools["🧰 Tools<br/>shell · fetch · files · search"]
    Agent -->|logs each step| Log["📒 events.org"]
    Agent ==>|done| Done["📦 Finished Workbook"]
```

**Private routes stay sealed.** A route is just a path inside the Workbook. Public paths are
plain; the ones you mark private are encrypted, and the Runtime hands over the key only
after an access check. A private page isn't hidden — it's unreadable without permission.

```mermaid
flowchart TD
    Open["👤 Open a private route"] --> Sealed["🔒 Sealed — needs a key"]
    Sealed --> Ask["⚙️ Runtime checks access"]
    Ask --> Q{"Allowed?"}
    Q -->|yes| Key["🔑 Key released<br/>unseal & view"]
    Q -->|no| Deny["✕ No key<br/>stays unreadable"]

    classDef ok fill:#28c84022,stroke:#28c840,stroke-width:1.5px;
    classDef no fill:#dc464622,stroke:#dc4646,stroke-width:1.5px;
    class Key ok
    class Deny no
```

## The primitives

Workbooks is a handful of small ideas that fit together. Each one does a single job.

**Workbook** — the format. Your code plus an Org layer that ties it together, bundled into
one self-contained `.html`. Holds code, data, and interface; can be a document, a database,
an app, or a container.

**Bundle** — the packer. Takes your source — real code files and the Org that connects
them — and packs it into the single `.html` (and back out again, so a Workbook is never a
black box). This is the step that turns a project into one portable file.

**Runtime** — the engine. A single Elixir/BEAM host with WebAssembly (wasmtime) inside.
Runs Workbooks, drives agents, and records everything it does to a queryable log
(`events.org`).

**Container** — safety. Every Workbook runs as a sandboxed WebAssembly component with its
own memory and time limits. It only gets the capabilities you grant it; untrusted code
can't reach past its box, and a crash inside never takes the host down.

**Compilers** — languages, in the sandbox. Code compiles *to* WebAssembly — never to native
machine code — right inside the sandbox. Pull a package and run it without trusting it.
C and Zig work today; Rust, Go, and Python are on the way.

**Agents** — the builders. An agent can author, test, ship, and publish a Workbook for you.
It works through a small set of tools — a shell, fetch, the file store, search — and writes
every step to `events.org`, so you can see exactly what it did.

**Memory** — context that doesn't drift. There is no separate memory database. A Workbook
keeps its code and its context together in one readable file, so an agent reads its context
straight from the work — which is what keeps it on track.

**OQL** — the query layer. A small language for reading and checking a Workbook's structure:
list its parts, validate it, or plan a build. The same kernel runs in the browser, the
desktop app, and the Runtime.

**Identity** — who made it. Each Workbook is signed with its owner's key (Ed25519, exposed
as a `did:key`), so anyone can verify a Workbook is genuine and unaltered. Logins are handled
with standard JWTs.

**Seal** — routing with auth built in. A Workbook is a bundle whose directory of paths *is*
its route table — every route is just a path inside the file. Routes you mark private are
**sealed** (encrypted), and the Runtime hands over the key only after an access check. So a
private page isn't hidden, it's unreadable without permission. Any frontend router plugs in
(SvelteKit, TanStack, React, SolidJS, Vite) through a thin adapter.

**Sharing** — your work, moved safely. Workbooks are backed by Git, so history, diffs, and
rollback come for free. They can also be published and fetched peer-to-peer over Radicle,
identified by the same keys above.

**Deploy** — shipping it. One image runs the Runtime in a local container or on a cloud
machine. `wb deploy` scaffolds the config and ships it.

## Install the desktop app

```sh
curl -fsSL https://workbooks.sh/install.sh | sh
```

Installs the latest [desktop release](https://github.com/workbooks-sh/workbooks.sh/releases)
(macOS · Linux). Already have the `wb` CLI? `wb desktop install` does the same. Or grab a
bundle straight from the releases page. On first launch the app's wizard connects an engine
— a local microVM (via krunvm) or a cloud engine — but it's optional: Workbooks opens and
weaves workbooks offline without one.

## Try it

```bash
wb run app.org      # run a workbook
wb publish app.org  # ship it
```

That's the loop.

<details>
<summary>Run from source, or deploy to your own server / the cloud</summary>

```bash
# Run the Runtime from source
cd runtime
mix deps.get && mix compile
iex -S mix                 # dev
MIX_ENV=prod mix release   # production build

# Deploy: one OCI image, run it locally or on a cloud machine
wb deploy init             # scaffold the config
wb deploy local            # run it in a local Linux container
wb deploy apply deploy.org # ship it to a cloud machine
```

The Runtime is one self-contained container: BEAM + wasmtime + the baked WASM artifacts.
The whole server lives in `runtime/host/`.

</details>

## What's in here

| Directory | What it is |
|-----------|------------|
| `runtime/` | **The product.** The Elixir host (`host/` — the agent loop, OQL, the file store, the web surface), the OQL kernel (Rust → `oql.wasm`) in `kernel/`, the WebAssembly interfaces in `wit/`, and the baked WASM commands in `build/`. |
| `desktop/` | The **workbook-native** desktop app (Tauri). Embeds the OQL kernel and edits/runs workbooks **offline, no server** — and optionally connects to a Runtime for agents and sync. See `desktop/README.md`. |
| `toolkits/` | Capability toolkits the Runtime discovers — like `presentation` (reveal.js) and `video` (hyperframes) — wrapped as agent skills. |
| `web/` | The landing page and the in-browser workbook viewer. |

## License

[Apache 2.0](LICENSE). Free and open source, end to end — the format, the Runtime, and the
desktop app.

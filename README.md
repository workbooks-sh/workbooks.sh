<p align="center">
  <img src="web/favicon.svg" width="80" alt="Workbooks">
</p>

<h1 align="center">Workbooks</h1>

<p align="center"><em>Software that's living, breathing, and yours.</em></p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-121316" alt="License"></a>
  <a href="https://github.com/workbooks-sh/workbooks.sh/pkgs/container/runtime"><img src="https://img.shields.io/badge/runtime-ghcr.io%2Fworkbooks--sh-121316" alt="Runtime image"></a>
  <a href="https://workbooks.sh"><img src="https://img.shields.io/badge/workbooks.sh-121316" alt="workbooks.sh"></a>
</p>

---

You've written this app before. A struct, a seed table, a function that scores it, a page
that shows it, a job that runs nightly. Each one lived in a different file, a different
language, a different tool — and the part that explained *why* lived in a doc nobody opened.

A **workbook** puts it back together. You write a folder of **`.work` files** — plain text
where **prose narrates and `do … end` blocks run**. No HTML wrapper, no code fences: a block
is self-delimiting, and its **first word names the kind** — `data`, `def`, `server`,
`client`, `agent`, `record`. You read it top to bottom like a document; the machine reads the
same text as an AST and runs it. The explanation and the program are finally the same file.

It's an **ecosystem, not a file format.** The dashboards, tools, and docs you build are the
same kind of thing the runtime itself is made of — so you learn the format by reading the
thing you're using.

## Quick start

```sh
curl -fsSL https://workbooks.sh/cli.sh | sh
```

Now write `leads.work` — prose explains, blocks run, the first word names the kind:

```
# Leads

This app ingests leads and ranks them. It turns on one record — a plain struct,
with types inferred from the defaults:

defmodule Lead do
  defstruct name: "", domain: "", revenue: 0, score: 0, status: :new
end

A `data` block is a typed table. It renders by default — this *is* the seed UI:

data :seed do
  %Lead{name: "Acme",   domain: "acme.com",  revenue: 4_200_000}
  %Lead{name: "Globex", domain: "globex.io", revenue:   900_000}
end

A `def` is a runnable unit, and the first word says *where* it runs. `server` runs on
the nexus; `client` runs in the browser, compiled to wasm:

server def score(lead) do
  %{lead | score: div(lead.revenue, 100_000)}
end

client def badge(lead) do
  if lead.score > 30, do: "🔥 hot", else: "cold"
end
```

Then fold the folder into one artifact, or develop live:

```sh
work weave .     # fold the tree into one shippable artifact
work dev .       # watch + re-weave on change (nexus hot-swaps)
work check .     # resolve [[refs]] + audit sandbox capabilities
```

## The four lanes

Every `.work` file mixes four kinds of content. That's the whole mental model:

| Lane            | What it is                            | Looks like                                          |
| --------------- | ------------------------------------- | --------------------------------------------------- |
| **Prose**       | rich text that explains, with live refs | `[[backlinks]]`, `#tags`, `work://` links, `:atoms` |
| **Declaration** | structure with no body                | a `defstruct` record, a list-of-atoms enum, a `data` table |
| **Code**        | a runnable block                      | a `def`, a `server` unit, a `client` island         |
| **Placement**   | the first word says *where* it runs   | `client` (browser/wasm) · `server` (nexus) · `sandbox :name` (capabilities) |

It's **AST-first**: every block parses to a real macro-call tuple through the one parser the
whole system shares — viewer highlighting, the code-graph extractor, and the build gate all
read the same tree, never a regex. Ask the graph *why* something is reachable, or generate
the WIT world a `sandbox` exports — straight off the AST.

## The `work` CLI — the reactor

One binary (written in Zig) operates on the tree. It runs the same native, in CI, and inside
the agent's wasm sandbox.

| Verb               | Does                                                       |
| ------------------ | --------------------------------------------------------- |
| `work weave <dir>` | fold a folder of `.work` files into one shippable artifact |
| `work dev <dir>`   | watch + re-weave on change; the nexus hot-swaps            |
| `work check <dir>` | resolve refs, audit declared sandbox capabilities          |
| `work why / near`  | code-graph dependencies — what reaches this, what's nearby |
| `work wit`         | the generated WIT world for a sandbox                      |
| `work deploy`      | stand a nexus up — locally (krunvm) or in the cloud        |

## The nexus runtime

The **nexus** (Elixir/BEAM) serves a woven workbook. Pull the published image:

```sh
docker run -p 4000:4000 ghcr.io/workbooks-sh/runtime:latest
```

It answers `GET /` (server-side render), `GET /data/:resource`, `POST /api/run` +
`/api/run/stream` for agents, `GET /health`, and a `/.well-known/workbooks-runtime`
capabilities handshake. `client` islands ship to the browser as wasm; `server` units, agents,
data, and sync run on the nexus.

The `/api/platform/*` **control plane** is the multi-tenant layer — org-isolated,
WorkOS-JWT-gated, with encrypted env vars. **Isolation is structural**: every record is keyed
by its owning org, so a tenant can never read across the boundary. It's adversarially tested,
not just trusted.

Stand your own up with the CLI — same image, locally or in the cloud:

```sh
work deploy init local     # scaffold a <work-deploy> config
work deploy apply          # bring it up
work deploy verify         # health-check it
```

## Repo layout

| Path           | What                                                       |
| -------------- | ---------------------------------------------------------- |
| `reactor/`     | the `work` CLI — author, build, run, deploy (Zig)          |
| `nexus/`       | the runtime — serve, agents, multi-tenant control plane (Elixir) |
| `workkits/`    | the kits — reusable toolkits a workbook imports and composes |
| `desktop/`     | the desktop app — one frontend, swappable local/runtime providers |
| `web/`         | the [workbooks.sh](https://workbooks.sh) site              |

## License

[Apache 2.0](LICENSE). Build on it.

— [workbooks.sh](https://workbooks.sh)

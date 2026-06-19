<p align="center">
  <img src="web/favicon.svg" width="76" alt="Workbooks">
</p>

<h1 align="center">Workbooks</h1>

<p align="center"><em>Software that's living, breathing, and yours.</em></p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-121316" alt="License"></a>
  <a href="https://github.com/workbooks-sh/workbooks.sh/pkgs/container/runtime"><img src="https://img.shields.io/badge/runtime-ghcr.io%2Fworkbooks--sh-121316" alt="Runtime image"></a>
  <a href="https://workbooks.sh"><img src="https://img.shields.io/badge/workbooks.sh-121316" alt="workbooks.sh"></a>
</p>

---

You write software as **`.work` literate files** — plain text where prose narrates and
`do … end` blocks run. The **`work` CLI** weaves a folder of them into one shippable
artifact; the **nexus runtime** serves it — data, agents, and a multi-tenant control plane.

It's an ecosystem, not a file format. The dashboards, tools, and docs you build are the
same kind of thing the runtime itself is made of — you read a workbook top to bottom and
build the app and learn the format at once.

## Quick start

Install the CLI:

```sh
curl -fsSL https://workbooks.sh/cli.sh | sh
```

Write a `.work` file — prose explains, blocks run, and the first word names the kind:

```
# Leads

This app ingests leads and ranks them. Here's the record the whole thing turns on —
a struct, with types inferred from the defaults:

defmodule Lead do
  defstruct name: "", domain: "", revenue: 0, score: 0, status: :new
end

A `data` block is a typed table that renders by default:

data :seed do
  %Lead{name: "Acme",   domain: "acme.com",  revenue: 4_200_000}
  %Lead{name: "Globex", domain: "globex.io", revenue: 900_000}
end

A `def` is a runnable unit; the first word places it — `server` runs on the nexus,
`client` runs in the browser (wasm):

server def score(lead) do
  %{lead | score: div(lead.revenue, 100_000)}
end
```

Then weave the folder, or develop live:

```sh
work weave .     # fold the tree into one shippable artifact
work dev .       # watch + re-weave on change (nexus hot-swap)
work check .     # resolve references + audit capabilities
```

## How it works

- **The `.work` format** — four lanes in every file: **prose** (rich text carrying live
  refs: `[[backlinks]]`, `#tags`, `work://` links), **declaration** (a `defstruct` record,
  an enum, a `data` table), **code** (a `def`, a `client` island, a `server` unit), and
  **placement** (the first word says *where* it runs — `client` in the browser via wasm,
  `server` on the nexus, plus an optional `sandbox :name` for capabilities). It's
  **AST-first**: every block parses to a real macro-call tuple, via the one parser the whole
  system shares.

- **The `work` CLI** (the Zig *reactor*) operates on the tree: `weave <dir> <out>` folds it
  into one artifact, `check` resolves refs + audits capabilities, `why`/`near`/`wit` give the
  code-graph deps + the generated WIT world, plus `graph`, `dev`, `deploy`, and `new`. One
  source — runs native, in CI, and inside the agent's wasm sandbox.

- **The nexus runtime** (Elixir/BEAM) serves a woven workbook: `GET /` (SSR), `GET
  /data/:resource`, `POST /api/run` + `/api/run/stream` (agents), `/health`, and a
  `.well-known/workbooks-runtime` capabilities handshake. The `/api/platform/*` **control
  plane** is the multi-tenant layer — org-isolated, WorkOS-JWT-gated, with encrypted env
  vars. Isolation is structural (every record keyed by its owning org) and adversarially
  tested.

## Run the runtime

Pull the published image:

```sh
docker run -p 4000:4000 ghcr.io/workbooks-sh/runtime:latest
```

Or stand one up — locally (a krunvm container) or in the cloud — with the CLI:

```sh
work deploy init local     # scaffold a <work-deploy>
work deploy apply          # bring it up
work deploy verify         # health-check it
```

## Repo layout

| Path           | What                                                  |
| -------------- | ----------------------------------------------------- |
| `reactor/`     | the `work` CLI — author, build, run, deploy (Zig)     |
| `nexus/`       | the runtime — serve, agents, control plane (Elixir)   |
| `workponents/` | example `.work` workbooks                             |
| `web/`         | the workbooks.sh site                                 |

## License

[Apache 2.0](LICENSE).

— [workbooks.sh](https://workbooks.sh)

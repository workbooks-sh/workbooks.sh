# `workbook` vs `work` — the split

Two CLIs, two scopes. Use the right one.

## `workbook` — the artifact lifecycle

Owned by the `workbooks-authoring` skill/toolchain. Operates on a single-file
workbook project.

| Command | Does |
|---|---|
| `workbook init` | scaffold a new workbook project |
| `workbook dev` | run it locally (tightest verification tier) |
| `workbook build` | bundle source → the runnable `.html` |
| `workbook unbundle <file.html>` | recover the editable source tree (lossless) |
| `workbook check` | validate the artifact |
| `workbook publish` | publish → prints a URL |

## `work` — the platform CLI

The Elixir escript. Operates on the runtime, toolkits, deploy, dev loop.
Relevant during authoring:

| Command | Does |
|---|---|
| `work content check [dir]` | content validation (alternative to `workbook check`) |
| `work compiler build <lang>` / `work compiler run` | the compiled-dep WASM lane |
| `work toolkit build palette [<runtime>]` | interpreted-runtime palette |
| `work publish apply` | platform publish path |
| `work sign` / `work verify` | sign / verify an artifact |

## Rule of thumb

The single-file artifact loop is `workbook …`. Anything touching the runtime,
toolkits, compilers, or deploy is `work …`. Never assume one binary does both.

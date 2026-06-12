# `workbook` vs `wbx` — the split

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

## `wbx` — the platform CLI

The Elixir escript. Operates on the runtime, toolkits, deploy, dev loop.
Relevant during authoring:

| Command | Does |
|---|---|
| `wb content check [dir]` | content validation (alternative to `workbook check`) |
| `wbx compiler build <lang>` / `wbx compiler run` | the compiled-dep WASM lane |
| `wbx toolkit build palette [<runtime>]` | interpreted-runtime palette |
| `wbx publish apply` | platform publish path |
| `wbx sign` / `wbx verify` | sign / verify an artifact |

## Rule of thumb

The single-file artifact loop is `workbook …`. Anything touching the runtime,
toolkits, compilers, or deploy is `wb …`. Never assume one binary does both.

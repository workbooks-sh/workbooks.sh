# `wb` CLI — canonical verb taxonomy (proposal)

A full redesign of the command surface so it's clear and communicable. Audited from
the live code: `runtime/host/cli.ex` (~29 verbs / 67 forms), `package_manager.ex`,
the 33 runtime routes in `web.ex`/`public_web.ex`, and `RUNTIME-CONNECT-PROTOCOL.org`.

## 1. Principles

1. **Group by the noun the verb acts on.** A reader should know *what* is being acted on
   from the group: a **workbook**, the **library**, the **runtime**, a **toolkit**.
2. **One word, one meaning.** Kill synonyms (bundle/pack, publish-as-render).
3. **One lifecycle spine**, stated once: `build → bundle → run → publish` for a workbook;
   `deploy` is a separate axis (the engine).
4. **The package manager is internal.** It powers `build`; it is not a user verb. Deps are
   declared in source (Cargo.toml / package.json / inline `:deps`), never hand-fetched.
5. **Local vs remote is explicit.** Kernel + assembly verbs run locally (no runtime);
   library/agent/workflow verbs drive a running runtime over RCP.

## 2. The objects (nouns)

| Noun | What it is |
|---|---|
| **workbook** | one portable file (org + code + data, assembled) |
| **source** | the multi-file authoring tree (org + code) a workbook is built from |
| **library** | the tenant's collection of workbooks/workspaces (git-backed, multi-) |
| **runtime** | the engine (the thing that runs workbooks / serves the API) |
| **toolkit** | an agent-skill package |
| **identity** | keys, signatures, provenance |

## 3. The lifecycle spine (say it this way)

```
author ──▶ build ──▶ bundle ──▶ run ──▶ publish
          (compile)  (assemble)        (ship to a surface)

deploy ── stand up the runtime engine   (orthogonal: about the engine, not a workbook)
```

- **build** = compile the source's code components → WASM (the package-manager step).
- **bundle** = assemble org + built code + data into ONE workbook file. (absorbs render + pack)
- **run** = execute a workbook / component.
- **publish** = put an *already-assembled* workbook on a surface (website/host). Distribution only.
- **deploy** = converge the runtime engine (local microVM or cloud). About the engine.

## 4. Canonical surface (grouped by object)

`L`=local (no runtime) · `K`=kernel (embedded, local) · `R`=drives a running runtime · `O`=local orchestration (spawns docker/git/wrangler/krunvm)

### workbook (the file)
```
wb build  [src]            L*  compile code components → WASM (package manager; resolves deps)
wb bundle [src] [-o out]   L   assemble org + code + data → one workbook (.wbundle/.html)
wb unbundle <file> [dest]  L   workbook → source tree            (was: unpack)
wb run <workbook> [args]   L*  execute a workbook / component
wb publish <workbook>      O   ship an assembled workbook to a surface (CF Pages/gh-pages/host)
        init|validate|apply    (declare-then-converge; config = publish.org)
```
`*` build/run need the in-sandbox compiler toolchain — bundled with the CLI or delegated to the runtime (see §7).

### source inspection (read the org; kernel, local)
```
wb query <file.org>   K   headlines / structure rows
wb plan  <file.org>   K   the build plan / WIT world        (was: tangle — see open Q)
wb lint  <file.org>   K   diagnostics
```

### library (the tenant's many workbooks; remote)
```
wb library                 R   list workspaces + members
wb checkout <member> <dir> R   borrow a member into a working dir
wb checkin  <member> <dir> R   pack + sign a member back
wb search <query>          R   cross-workbook search  (--semantic | --literal | --sql)
wb store  <slug>           R   archive a workspace to durable storage
wb store --list                list stored                       (was: stored)
wb fetch  <key> [out]      R   restore from storage
```

### runtime (the engine)
```
wb deploy   init|validate|apply|status|logs|down|local|doctor   O   stand up the engine
wb rt       status|get <path>|post <path> [json]                R   raw RCP escape hatch
wb workflow run|plan <file.org>                                 R   run/plan a workflow DAG   [NEW]
wb agent    run|status|logs <id>                                R   long-horizon agent runs    [NEW]
wb workbook list|show <id>|deploy <id> <org>                    R   manage deployed workbooks  [NEW]
```

### toolkit (agent skills)
```
wb toolkit list|show|search|verify|build|run   L/R   discover + build + run agent skills
```

### identity & provenance
```
wb sign   <file> [-o out]   L   embed a did:key provenance manifest
wb verify <file>            L   check signature + integrity
wb ledger <slug>            R   verify a run's signed ledger
wb mirror <url> | --forge … O   mirror the tenant repo to a git host
wb federate                O   federate over Radicle (P2P)        (was: radicle)
```

### config + system
```
wb var set|get|list|ref     local variables / secrets (ref-only)
wb telemetry [<slug>]       run index / one run's summary
wb compiler list|build|run  in-sandbox compiler tooling (advanced)
wb isolation                show the isolation-tier ladder (info)
wb desktop install|open     the GUI app
wb version
```

## 5. Collisions resolved (before → after)

| Was (confusing) | Now | Why |
|---|---|---|
| `bundle` (single org) **+** `pack` (workspace) | **`bundle`** (one verb; composes any source) | both meant "assemble"; one word |
| `publish apply` *renders* org→HTML **and** ships | **`bundle`** renders/assembles; **`publish`** only ships | publish = put a workbook on a surface (your original meaning) |
| `publish` (workbook→web) vs `deploy` (engine→infra) | kept separate, by object: **publish = workbook**, **deploy = runtime** | two different nouns, no longer look alike |
| `unpack` | **`unbundle`** | mirrors `bundle` |
| `wb query <org>` (kernel) vs `library query <sql>` | kernel stays **`query`**; library SQL folds into **`search --sql`** | the word "query" meant two things |
| `stored` | **`store --list`** | one storage verb family |
| `radicle` | **`federate`** | name the action, not the tool |
| `deploy build` / `deploy publish` (push runtime image to ghcr) | **maintainer/CI only**, not a user verb (platform release ≠ `wb deploy`) | matches the 3-layer release rule |

## 6. Gaps filled (routes that had no verb)

The runtime exposes routes with no CLI today. New first-class verbs (thin RCP clients):
- **`wb run`** — execute a workbook/component (was implicit).
- **`wb workflow run|plan`** — `POST /api/workflow` (+`?plan=1`).
- **`wb agent run|status|logs`** — `POST /api/run`, `GET /api/run/:id[/stream]` (was: hand-rolled `wb rt post`).
- **`wb workbook list|show|deploy`** — `GET /api/workbooks`, `/api/w/:id/org`, `PUT /w/:id`.

## 7. Where each verb runs (maps to the Rust `cli/` crate)

- **Kernel, local** (`query`/`plan`/`lint`): embedded `oql` rlib. No runtime. ✅ wired.
- **Assembly, local** (`bundle`/`unbundle`/`sign`/`verify`): kernel + zip + fs in the CLI. No runtime.
- **Orchestration, local** (`publish`/`deploy`/`mirror`/`federate`): spawn `wrangler`/`git`/`docker`/`krunvm`/`fly`. No runtime. ✅ deploy wired.
- **Remote** (`library`/`search`/`store`/`fetch`/`workflow`/`agent`/`workbook`/`rt`/`telemetry`/`ledger`): RCP client → a running runtime. ✅ client wired.
- **`build`/`run`**: need the in-sandbox compiler toolchain (the package manager). Two options — **(a)** the CLI embeds `wasmtime` + the compiler `.wasm` artifacts (heavy, fully local), or **(b)** delegate to a running runtime that owns the compilers. Open decision (§8).

## 8. Decisions (LOCKED 2026-06-09)

1. **`tangle` stays.** It's the org-mode / literate-programming term of art. Not renamed to `plan`.
2. **`build`/`run` delegate to the runtime.** The compiler toolchain is the ~600 MB in-sandbox
   compilers package (gitignored, hours to provision, ships in the runtime image). Embedding it
   in the CLI binary is a non-starter and defeats the small-binary goal. `build`/`run` therefore
   need the engine (which already has the compilers + wasmtime + package manager). The CLI stays
   thin and delegates; with no server, the user gets a local engine via `wb deploy local`
   (krunvm runs the runtime image *with* compilers) or the desktop app. The CLI errors helpfully
   when no engine is reachable.
3. **Flat by default; nest only multi-operation families.** Single-action verbs are flat
   (`checkout`, `search`, `bundle`, `sign`, …). A noun with several detailed ops nests:
   `deploy`, `publish`, `toolkit`, `var`, `rt`, `agent`, `workflow`, `workbook`, `compiler`,
   `desktop`. No artificial `wb dev`/`wb runtime` parent grouping.
4. **By the §8.3 rule:** `var` + `compiler` nest (sub-ops); `telemetry` + `isolation` stay flat.

### The deciding axis — local vs engine-backed
- **Local in the CLI (no engine):** `query` `tangle` `lint` `bundle` `unbundle` `sign` `verify`
  `publish` `deploy` `mirror` `federate` `var`
- **Engine-backed (delegate to a running runtime over RCP):** `build` `run` `library` `checkout`
  `checkin` `store` `fetch` `search` `workflow` `agent` `workbook` `telemetry` `ledger`
  (engine-backed verbs error with "no runtime — try `wb deploy local`" when none is reachable.)

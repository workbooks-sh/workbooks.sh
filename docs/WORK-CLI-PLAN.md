# `work` — the universal ecosystem CLI (full plan)

`work` is the **front door to the workbooks ecosystem**: one binary you download that does
everything — author, build, weave, run, deploy, manage. It is **not** "nexus's CLI." nexus is one of
several systems it speaks to. Like `gh` / `stripe` / `fly`: a single coherent surface over many
backends, unified by a context/target model.

## 1. The decision (settled)

- **`work` is a SIBLING package, not inside nexus.** A universal front door must cold-start in ms and
  `curl|sh`-install clean (can't carry the server's wasmex NIF / Bandit), and must route to many
  systems (can't live inside any one of them). The old escript's `app: nil` dance proves the coupling
  is already a smell.
- **A shared `work_core` library holds the local toolchain** — literate parse, code graph, WIT gen,
  extractors, weave/bundle, deploy-config, sign/verify. No NIF, no server. **This also kills the
  duplication** (literate/graph are currently copy-pasted across `runtime/` and `nexus/`).
- **Three packages:** `work_core` (lib) ← consumed by both `nexus` (server) and `work` (CLI).
- **Now is the time** — the duplication is already accruing and the CLI is the piece most welded to
  the dying runtime; extracting `work_core` while nexus is young is the cheapest it will ever be.

```
            ┌──────────────┐   local file ops (offline)
            │  work (CLI)  │───────────────┐
            └──────┬───────┘               ▼
       context/auth│router          ┌─────────────┐
   ┌───────────────┼──────────────┐ │  work_core  │ (parse·graph·wit·weave·bundle·sign)
   ▼               ▼              ▼ └─────────────┘
┌────────┐   ┌──────────┐   ┌──────────┐        ▲
│ nexus  │   │  cloud   │   │ desktop  │  forges/└── also linked into nexus (no dup)
│(engine)│   │ control  │   │  shell   │  radicle/
└────────┘   │  plane   │   └──────────┘  registries
             └──────────┘
```

## 2. The systems `work` talks to (the backends)

| Backend | What it serves | Transport | Verbs (examples) |
|---|---|---|---|
| **Local toolchain** (`work_core`, in-process) | author/build offline | none | check, why, near, wit, lint, structure, weave, bundle, sign, verify |
| **A nexus** (local or any remote; many) | the engine: compile, agents, store/sync, deploy-apply | RCP/HTTP | compile, run, kit, channels, deploy apply, logs |
| **Cloud control plane** (hosted product) | org→nexus→workspace registry, auth, billing | HTTPS | login, whoami, nexus, workspace, org, billing |
| **Desktop app** | drive the running shell | local IPC/RCP | app status/open-tab/theme |
| **Forges / Radicle / registry** | publish, mirror, toolkits | git/HTTP | mirror, radicle, publish, kit promote |

## 3. The unifying mechanism — context & router (the "one tool" feeling)

Mirrors the platform's own **one-Host-surface / many-providers** canon — the CLI is the Dock membrane
at the terminal.

- **Context** = `{ auth identity, org, nexus (local|url), workspace, output mode }`. Stored at
  `~/.work/context.html` (HTML, not JSON — on-canon; a `<work-context>` element). `work ctx use <name>`,
  `work ctx list`, like `kubectl config`.
- **Auth** = `work login` against the control plane (WorkOS device flow) → token in the OS keychain.
  Local-only use needs no login (offline-first).
- **Router** = each verb declares which backend it targets; the router resolves the active context and
  dispatches: a local op runs in `work_core`; a remote op picks the right nexus/control-plane endpoint.
  One verb, right backend, transparently.
- **`--nexus <url>` / `--workspace <w>` / `--json`** override context per-invocation.

## 4. The verb surface (unified, reorganized into noun groups)

Today's 31 runtime verbs get regrouped under a discoverable taxonomy. `work` (no args) prints the
grouped map; `work help <group>` drills in.

- **author / literate:** `check`, `why`, `near`, `wit`, `lint`, `structure`, `graph` — over `.work`
  trees, all local (`work_core`). *(Exist + pass on `workponents/sales/**`; just need surfacing.)*
- **build / weave:** `weave` (the literate→WIT→wasm→one-html pipeline; today's `bundle`), `unweave`
  (`unbundle`), `pack`, `build`. Local compile delegates heavy lanes to a nexus.
- **run:** `run <agent>`, `kit` (toolkit discovery/build/run), `channels`, `models`/`model`, `dev`
  (local verify loop + the watch/push-to-live mode, §7).
- **deploy:** `deploy init|apply|status|verify|logs|down|doctor|ci` + `deploy local|cloud`. §6.
- **publish / share:** `publish` (render→live URL), `sign`, `verify`, `mirror`, `radicle`, `library`,
  `pack`.
- **platform:** `login`, `whoami`, `ctx`, `org`, `nexus`, `workspace`, `billing`, `var`, `env`,
  `workgate`, `app`, `desktop`.
- **meta:** `version`, `help`, `telemetry`, `ledger`, `isolation`.

## 5. Literate build + weave (how work-files flow)

The build unifies onto the **`.work` literate source of truth** (today `bundle` rides the old HTML
`<work-component>` tangle path; WIT generation is built + 32/32 green but not yet the default build).

```
.work tree ──parse(literate.ex)──▶ nodes ──per-lang extract(extract.ex)──▶ AST surface
   │                                                                          │
   └──code graph(graph.ex): refs/caps/deps──▶ work check / why / near        ▼
                                                              WIT worlds(wit.ex) per unit
                                                                              │
                              compile lanes (sandbox wasm; heavy → a nexus)  ◀┘
                                                                              │
                                       weave ──▶ ONE gzipped self-contained .html (wbundle-html/1)
                                                  static floor + nexus-backed hydration when declared
```

- **`work_core` owns** parse → extract → graph → WIT → weave (pure/local). **Heavy compile** (rust/zig
  componentize) is delegated to a nexus over RCP (or run locally if a local nexus is up).
- Landing this is **WORK-FORMAT-IMPLEMENTATION.md §1–§4** (componentize + WIT-informed build replacing
  `tangle_plan`). After it, `work weave` is literate-native; the HTML path becomes a serialization, not
  a second model.

## 6. Deploy (a method for deployment)

- **Config = `deployment.html`** — a `<work-deploy engine-place="local|cloud" …>` element (HTML, no
  JSON). Secrets from ENV, never the file.
- **`work deploy apply`** routes by context: **local** = the one OCI runtime image in a krunvm/container;
  **cloud** = provision/deploy to the org's nexus via the control plane (Fly today). The CLI is a
  **client** — the heavy lifting is the nexus image + control plane, not baked into the CLI.
- **Wire nexus deployment** (today a stub `nexus/lib/deploy.ex`) so "deploy *the nexus*" is real, not
  only the legacy runtime image.
- Verbs: `init / ci / validate / apply / local / doctor / status / verify / logs / down / build /
  publish` — already complete in runtime; port onto the CLI's client model.

## 7. Push-to-live (the north star)

`work dev` (a.k.a. `work watch`): file-watch the `.work` tree → **incremental weave** (only changed
units re-extract/re-WIT/re-compile) → **hot-swap** the artifact into the running local-or-cloud nexus
→ live reload. Convex-like instant push. Built on §5's incremental graph + §6's apply. This is what
makes the CLI feel alive, not batch.

## 8. The logging ergonomics (the delight)

Codify the demo palette (`workponents/work-format.css .term`, `sales/salesapp.html`) — today it exists
only in HTML — as a **structured logger in `work_core`**, dual-output: ANSI for humans, `--json` for
agents (the tool-boundary JSON exception; everything else stays HTML).

- **Palette (exact):** Geist Mono; bg `#16181d`, text `#cdd2da`; prompt mint `#aee5c2`, cmd white-bold,
  ok sage `#7fd6a0`, path blue `#8fc7f0`, num peach `#e7b894`, warn gold `#e3b341`, dim `#7e8590`;
  glyphs `✓ ✗ · ⟨`, blinking-mint cursor for prompts.
- **Logger API:** `Work.Log.cmd/path/ok/warn/dim/num/step/spinner` — one facade every verb emits
  through, so output is consistent and *designed*. Long verbs (`weave`, `deploy`) stream per-step lines
  + a spinner; `--json` emits the same events as structured records for agents.
- **Example:**
  ```
  ⟨ work weave sales/ → sales.html
  ✓ parsed 12 units · 18 edges            check green
  ✓ wove 24 files · compiled 6 wasm · 2.3MB embedded   1.4s
  ⟨ work deploy apply
  ✓ image ghcr…/runtime:sha · krunvm up · :4000 healthy
  ```
- **Dogfood:** the CLI's own status/roadmap is authored as a workbook, rendered by the same primitives.

## 9. Migration & guardrails

- **`work_core` extraction first** (P0) — move literate/graph/wit/extract/bundle/deploy-config out of
  `runtime/` + `nexus/` into the shared lib; both depend on it; delete the duplicates.
- **Name guardrail stays** (`cli_name_test.exs` pins `work`); point it at the sibling escript.
- **Per-verb port + retire:** as each verb moves onto the CLI client/`work_core` model, retire the old
  runtime CLI clause. Update the `curl|sh` installer to ship the sibling.
- **NO-JSON preserved:** configs/contexts/manifests are HTML (`<work-deploy>`, `<work-context>`); the
  logger's `--json` is the single tool-boundary exception, for agent consumption.
- **Offline-first:** every local verb works with no auth and no network.

## 10. Phasing (each phase shippable, build green, committed per win)

- **P0 — `work_core`:** extract the shared toolchain, de-dupe. **DONE** — `work_core` holds
  Literate/Graph/Extract/Capabilities/Wit; `nexus` depends on it (124 green), `work_core` 37 green.
  *Runtime de-dup consciously SKIPPED:* the old runtime is the live-but-dying tier and its `wit` has
  diverged + couples to its own `Workbooks.Dock`; shimming it is throwaway work that retires with the
  runtime. The de-dup that matters — the future tiers (nexus + the CLI) — share one home.
- **P1 — CLI shell + logging:** stand up the sibling `work` escript; the context/auth/router; the
  structured logger (palette); port the NIF-free local verbs (check/why/near/wit/lint/structure/weave);
  surface the literate verbs in `help`. Delight lands here.
- **P2 — literate build unification:** WORK-FORMAT-IMPLEMENTATION §1–4; `work weave` goes literate-native.
- **P3 — deploy as client:** port deploy verbs onto the client model; wire **nexus** deployment; local
  (krunvm/container) + cloud (control plane / Fly).
- **P4 — push-to-live:** `work dev` incremental weave + hot-swap.
- **P5 — platform surface:** `login/ctx/org/nexus/workspace/billing`; flip the canonical name to the
  sibling; retire old runtime CLI verbs; update installer.

## 11. Risks / open

- **Engine-verb parity** between nexus and the dying runtime during migration — port behind the client
  model so the CLI is backend-agnostic.
- **WIT build land (P2)** is the deepest item (gated on componentize compile cores) — sequence it after
  the CLI shell so the ergonomics ship first and don't wait on it.
- **Control-plane surface (P5)** depends on the hosted product's auth/registry being callable — already
  largely built (WorkOS/Fly/Neon); confirm the client endpoints.
</content>

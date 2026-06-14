# Workbooks Documentation System — Architecture & Build Plan

**Status:** Design (Part 1). Authoritative for Part 2 implementation.
**Site:** `docs.workbooks.sh` (CF Pages project `workbooks-docs`, already provisioned, currently minimal).
**Distinct from:** the hand-rolled marketing/learn site at `workbooks.sh/learn/*` (those stay as the EXPLANATION tier; we link them, never duplicate).

---

## 0. Core decision: do not greenfield, do not adopt a framework

The hard parts already exist in-repo. The job is to **name, harden, and skill-ify** them, not build from scratch and not import Mintlify/Docusaurus/Starlight.

- `web/docs/` is already an org-authored docs tree with a `site.org` nav manifest and Diátaxis-shaped sections (`start/ concepts/ build/ run/ distribute/ workbooks/ reference/`) and `:PUBLISH_*:` props pointing at `workbooks-docs` → `docs.workbooks.sh`. It already renders to `web/docs/dist/`.
- `toolkits/orgitorial/` is a zero-dependency org→HTML renderer + editorial CSS that runs in browser, Node, AND the QuickJS-wasm lane. This is the renderer. No React, zero shipped JS, on-brand.
- `wbx tangle | query | lint <file.org>` are shipped native CLI verbs (`cli/src/main.rs`). `tangle` is already a read-only derivation from an org document to a typed JSON build plan, linking the kernel natively (no server).
- `web/learn/.audit/AUDIT.md` is a hand-run, per-claim-with-`file:line`-evidence drift audit. We are automating exactly that audit.

Off-the-shelf tools would force markdown-not-org (drift-blind to our `.ex`/`.rs`), ship React or a Node toolchain we can't run in-sandbox, or hand control to a SaaS — each violates the org/tangle + WASM + self-hosting canon.

**Net of the whole plan:** add ONE CLI verb family (`wbx docs *`, keystone `wbx docs drift`), ONE anchor convention (`docs:name:start/end` in source + `:SRC:`/`:SRC_HASH:` drawers), and ONE forced honesty field (`:MATURITY:`/`:STATUS:`). Reuse tangle's derivation discipline, the content-addressed cache, the orgitorial renderer, and `publish/site.ex`. ~1 week, not a migration.

---

## 1. Information architecture (Diátaxis, every surface)

### 1.1 The four corners, mapped to source-of-truth shape (not product area)

Group by **generability**, because shape dictates strategy:

| Diátaxis corner | Reader intent | Source & owner | Depth discipline |
|---|---|---|---|
| **Tutorial** (`start/`) | "walk me to first success" | hand-written org, human-owned, pinned to a tested transcript | SHALLOW + complete. 1 happy path, no branches. Max ~3–4 total. |
| **How-to** (`build/ run/ distribute/`) | "I have a goal, give me steps" | hand-written org, human-owned | MEDIUM. Goal-titled ("Grant a socket capability"). One per real job. |
| **Reference** (`reference/`) | "exact verbs/params/caps" | **AUTO-TANGLED from code**, machine-owned | EXHAUSTIVE + flat. Tables only, zero narrative. |
| **Explanation** (`concepts/` → links to `learn/*.html`) | "why is it like this" | the existing `/learn` deep pages ARE the explanation tier | DEEP narrative. Reuse, do not rewrite. |

**Key call:** the `/learn` deep pages are NOT reference and must never be rewritten as reference. `concepts/isolation.org` *links to* `learn/safe-powers.html`. One canonical explanation, referenced from docs. This kills the duplication-drift between the two bodies of writing.

### 1.2 Section tree (re-spine of existing `site.org`)

```
start/        Tutorial   install · first workbook end-to-end · first toolkit
concepts/     Explanation (thin org stubs → link to /learn deep pages)
build/        How-to     authoring workbooks + toolkits, languages, dock SDK
run/          How-to     invoke, isolation tiers, the fabric
distribute/   How-to     package & sign, install/registry, federation
deploy/       How-to     wb deploy (USER tool) — krunvm/podman/docker/fly
reference/    Reference  AUTO-GENERATED, one page per self-describing surface
maturity/     Honesty    the Capability Matrix (auto-aggregated, see §3)
```

### 1.3 Seven surfaces × where truth lives × doc strategy

| Surface | Truth lives in | Reference (auto-gen) | Hand-written | Drift mechanism |
|---|---|---|---|---|
| **wbx CLI** | `cli/src/main.rs` (clap), `cli/SPEC.md`, `cli/TAXONOMY.md` | verb tree, flags, exit-code map, env vars, `Out` JSON envelope | lifecycle spine `build→bundle→run→publish`, local-vs-engine axis, AX/DX mode model | clap-markdown via `cargo xtask gen-docs`; CI `git diff --exit-code` |
| **Nexus / runtime RCP API** | `runtime/host/web.ex` + `public_web.ex` (~50 routes), `runtime/docs/RUNTIME-CONNECT-PROTOCOL.org` | route table (method/path/auth), `@public` allowlist from `auth.ex`, JSON envelopes | what the Nexus is, Host/Dock membrane, provider routing | route table generated from router introspection; CI diff |
| **Nexus engine internals** (101 `.ex`) | `runtime/host/*.ex` clusters (agent, isolation/policy, brokers/Dock, build/compilers, provenance, storage) | — (too internal for full API ref) | architecture + concept docs, one per cluster; cap-tier matrix from `policy.ex:22-25` | hand-written; each load-bearing claim carries a `file:line` anchor (the AUDIT method) |
| **Browser (desktop)** | `desktop/src/lib/` (`platform/webHost.ts` = Host seam, `rcp/`, `oql-wasm/`, `org-renderer/`) | Host capability/provider surface | install, offline-first boot, onboarding gate ("engine state in titlebar, not a blocking gate") | hand-written; honesty mandatory ("UI is a workbook" is **north-star**, flag it) |
| **Toolkits** | `toolkits/*/manifest.org`, `toolkits/AUTHORING.org`, `runtime/docs/TOOLKITS-V3.org` | catalog auto-harvested from each `:toolkit:` node + skill index + `status` field | the docs toolkit authoring guide itself | tangle the catalog table FROM the manifests; `README.md` drift dies |
| **Compilers / lanes** | `runtime/compilers/{c,rust,go,zig,js,svelte}/` + per-lane `README.org` | lane matrix: language → status (proven/partial) → recipe path | "how a CLI/crate/npm becomes a WASM command" | harvest per-lane `README.org` front-matter |
| **Deploy-kit / kernel-oql** | `cli/deploy-kit/`, `cli/src/deploy/mod.rs`; `runtime/kernel/` (`lib.rs`, `wit/`, `browser_abi.rs`) | provider matrix (krunvm/podman/docker/fly); kernel WIT world → API ref | `wb deploy` user verbs; **the 3-layer release rule** (do NOT conflate compilers package / runtime image / `wb deploy`) | WIT is self-describing → gen from `kernel/wit/`; deploy from provider configs |

### 1.4 URL scheme

- One markdown/org file per page → one canonical `.html` URL: `https://docs.workbooks.sh/<section>/<slug>`.
- Each HTML URL has a sibling `.md` at `<section>/<slug>.md` (agent payload, §4).
- `/llms.txt`, `/llms-full.txt`, `/sitemap.xml`, `/robots.txt`, `/maturity` at root.
- Versioning: **single `latest`** tracking main; the drift gate guarantees it matches deployed code. Add `/v1/` path-prefix versioning (Astro/Stripe style, not a branch fork) only at the first breaking wbx/RCP release. Snapshotting versions pre-1.0 multiplies drift surface for zero users.

---

## 2. Drift mechanism — org tangle/untangle tied to real code

The founder's tangle instinct is **correct, but only for the Reference corner** (and for the `:EVIDENCE:` of every honesty claim). Tutorials/how-tos/explanation are prose that *should* be human-authored and can't be tangled. Reference is exactly where the current docs already drifted (`reference/cli.org` still says `wb` not `wbx`, missing verbs). So: **Reference = untangled-from-code, not authored.**

We reuse three existing primitives — `tangle`'s read-only derivation, the content-addressed cache key, and the claims-ladder — and add one CI verb. No new derivation engine.

### 2.1 Authoring contract — pull, never paraphrase

A doc never hand-writes a signature, flag, config key, route, or capability name. It declares a **named extraction** with a property drawer pointing at the truth:

```org
* wbx CLI :reference:
  :PROPERTIES:
  :SRC:       cli/src/main.rs#Subcommand     ← live anchor (region in source)
  :SRC_HASH:  a1b2c3                          ← hash of extracted region at last tangle
  :STATUS:    ships-today                     ← ships-today | partial | north-star | wall
  :OWNER:     cli
  :END:
#+begin_src text :tangle-from wbx://help/tangle   ← runs the real binary, inlines help
#+end_src
```

Three backed extraction kinds, all using tools that already exist:

1. **CLI help** — `:tangle-from wbx://help/<verb>`. Source of truth is clap (`wbx <verb> --help`, `wbx completions`, and a new `wbx schema --json` dumping every verb/flag). Build runs the real binary, inlines.
2. **Code signature / snippet** — `:tangle-from runtime/host/policy.ex#minimal` extracts a fenced anchor. Convention: in code, mark `# docs:minimal:start … # docs:minimal:end` (Elixir) / `// docs:...` (Rust). Build greps the anchor, inlines verbatim **with its `file:line` citation** — the same citation the AUDIT cited by hand.
3. **Capability / config / route matrix** — `:tangle-from kernel://tangle-plan` (the `imports`/`uses` surface `wbx tangle` already emits), `policy.ex` tiers, the route table from `web.ex`/`public_web.ex`, the lane matrix from compiler `README.org`, the WIT world from `kernel/wit/`. Derived, never typed.

### 2.2 The drift check — `wbx docs drift` (CI gate, the keystone)

A new verb beside `tangle`/`lint` in `cli/src/main.rs`. For each `:SRC:`/`:tangle-from` block it re-extracts the live region, re-hashes, and **diffs against what's committed** (`:SRC_HASH:` + a content-addressed digest per block stored in `docs/.tangle.lock`, reusing the same content-addressed cache-key idea already in the tangle/build lane).

- Code/help changed, doc hash stale → **error**, prints the diff and the `file:line`. This is the "code changed but docs didn't" signal — drift detected mechanically, not by review. (Mirrors Pulumi `--expect-no-changes` / driftctl CI-gate-on-diff; no external tool does doc↔code-signature drift, so this is novel-but-grounded.)
- A `ships-today` page may not reference a `:SRC:` that doesn't exist → fail.
- Reference rows that map to no shipping code literally can't be generated → cannot over-claim.
- CI: a GitHub Action runs `wbx docs drift` on every push to main, sitting beside `runtime-image.yml`. Red = drift.

### 2.3 Untangle — propagate doc edits back to code anchors

`wbx docs untangle` is the reverse for the *editable* half only. When an author fixes an inlined **example** in the `.org`, untangle writes it back to the `docs:anchor:start/end` region in the source file (the literate round-trip). Signatures/help/routes are **read-only** (code owns them); only example/anchor regions are untangle-targets. Keeps the `.org` as the working surface without forking code.

### 2.4 Reverse-generation path (for surfaces with no inline anchor)

For whole tables (CLI verb tree, RCP routes, toolkit catalog, lane matrix, WIT API): a `cargo xtask gen-docs` (+ an org harvester) regenerates between `# BEGIN GENERATED / # END GENERATED` markers, then CI `git diff --exit-code`. Same gate, table-granularity instead of block-granularity.

---

## 3. Honesty convention — capability/maturity matrix + gap/promise marking

The AUDIT proves the disease: ~90% true, but the wrong 10% is concentrated and predictable — present-tense claims about **composed/partial** primitives (two-way kanban, "no server", self-running schedule, autopoet, in-sandbox `wbx` parity). The fix is not prose review; it's a **forced status field that cannot be omitted**, mapped to a tiny opinionated vocabulary, drift-tied to the same `:EVIDENCE:` anchors.

### 3.1 Four tiers (not GA/Beta/Experimental — Workbooks has no support SLA)

- **`ships-today`** — verifiable now against a named `file:line` (e.g. `sealed.ex`, `policy.ex:22`). Most of the engine. Requires `:EVIDENCE:`.
- **`partial`** — the primitive exists but the feature as described is composed/scoped (the audit's #1 category: kanban, disk-grows, did-it-do-well). Requires `:EVIDENCE:` **and** `:CAVEAT:`.
- **`north-star`** — intended; code may be Phase-1 stub or absent (autopoet, "UI is itself a workbook", BYOD persistence). Renders visually distinct; **never present-tense prose**. Requires `:CAVEAT:`.
- **`wall`** — known-impossible-as-described under the architecture; maps to **BEDROCK / BRIDGE / FORGE** (from `runtime/.campaign/WALLS.md`). Requires `:WALL: bedrock|bridge|forge`. This is Workbooks' credibility moat — documenting *why* native-exec/JIT won't ship in-guest is more honest than any competitor.

### 3.2 Authoring (org metadata, fail-closed lint)

```org
* Two-way kanban
  :PROPERTIES:
  :MATURITY:  partial
  :EVIDENCE:  runtime/host/board.ex:L?-?
  :CAVEAT:    one-way regen from bd; no org-backed drag writer yet
  :WALL:      none
  :SINCE:     2026-06
  :END:
```

`wbx docs lint` (mirroring `mix compile` as first gate) **fails the build** if a required field for the declared tier is missing, OR if an `:EVIDENCE:` path doesn't exist in the tree (a moved/deleted line breaks docs CI — the founder's tangle instinct applied to truth, not just code blocks). This is the claims ladder as a drift state machine: an UNKEPT claim cannot silently ship. `north-star` claims render only under the explicit north-star band; nothing renders to the `ships-today` HTML unless its gate passes.

### 3.3 Rendering — one tangle step, three surfaces, one source

A tangle step emits `docs/maturity.json` (the authoritative table — **commit it**, it's the audit artifact). Consumed three ways:

1. **Inline badge** — colored pill (`partial` = amber) next to any feature mention. Generated, never hand-typed (orgitorial CSS renders it).
2. **Per-page frontmatter rollup** — a page's worst-tier status flows into the markdown frontmatter the SEO/agent layer emits, surfacing in HTML `<meta>` and `llms.txt` descriptions.
3. **`/maturity` — the Capability Matrix page** — every capability × tier × evidence × caveat × wall, grouped by surface (browser / nexus / wbx / runtime / toolkits / deploy-kit / kernel-oql). This *is* the honest answer to "what actually works"; the page LLMs and skeptical engineers cite.

The `/learn` explanation pages get the **same badge component** from the **same** `maturity.json` (resolves audit P3 #13) — no second place to drift.

---

## 4. llms.txt / markdown / SEO layer

The docs already compile org → `dist/*.html`. Extend that **one tangle step** to also emit each page's `.md` sibling plus the aggregate AI/SEO artifacts. Generate everything; hand-author nothing.

### 4.1 Files generated from the org build (into `web/docs/dist/`)

Per page `foo/bar.org`:
- `foo/bar.html` — human page (already produced).
- `foo/bar.md` — org body tangled to GFM, frontmatter stripped, code-fenced, links rewritten to absolute `https://docs.workbooks.sh/...`. The agent payload. **Keep the `[partial]`/`[north-star]` badges verbatim in the GFM** so agents ingest the honest state, not the aspirational one.

Site-wide (into `docs.workbooks.sh/`):
- **`/llms.txt`** — the index: H1 "Workbooks Docs", one-line blockquote, sectioned link lists (Start / Concepts / Build / Run / Distribute / Reference / Maturity) where each link points at the `.md` URL with a one-line summary. Distinct from the marketing `workbooks.sh/llms.txt` (that stays the product index).
- **`/llms-full.txt`** — concatenation of every page's `.md` in nav order, `<!-- page: /path -->` delimited; fed by `maturity.json` so an LLM knows `partial` from `ships-today`. Cap by section if it exceeds ~1MB.
- **`/sitemap.xml`** — auto-generated from the dist tree (drop the stale hand-curated `web/sitemap.xml`); `<lastmod>` from git commit date of the source `.org`; only canonical `.html` URLs.
- **`/robots.txt`** — `Allow: /`, both `Sitemap:` lines; do NOT block AI crawlers (we want ingestion).

### 4.2 Per-page HTML `<head>` (one template, injected by the renderer)

- `<link rel="canonical">` self URL (the `/learn` pages have zero canonical today — fix there too).
- `<link rel="alternate" type="text/markdown" href=".../bar.md">` — points agents at the md sibling.
- **schema.org JSON-LD**: `TechArticle` for concept/guide pages, `APIReference` for `reference/*`. Fields from org frontmatter (`#+TITLE`, `#+DESCRIPTION`, `dateModified` from git). Add `TechArticle` to `/learn` in the same pass (it emits none today).
- OpenGraph/Twitter from `#+TITLE`/`#+DESCRIPTION` (reuse existing `og.jpg`).

### 4.3 Serving (Cloudflare `_worker.js`)

1. **Extension**: `/foo/bar.md` is a real file in dist — add `md` to the existing `ASSET_RE` (it covers `.txt` but not `.md`) for edge caching, and set `text/markdown; charset=utf-8` explicitly (CF defaults md to octet-stream).
2. **Content negotiation**: for any `*.html`/extensionless doc route, if `Accept` contains `text/markdown` or `text/plain`, rewrite to the `.md` sibling and serve it (~8 lines, no origin round-trip — both files are in the Pages tree). Matches the 2026 Mintlify-established `?.md` + `Accept` norm.
3. `llms.txt`/`llms-full.txt` already match `.txt` in `ASSET_RE` — just ensure they're emitted into dist root.

### 4.4 On-site search

Build a **Pagefind** index over `dist/` as the last build step — zero-infra, static, runs at the edge (fits the "no server to view docs" canon). Emits `/pagefind/` consumed by a small client widget. No Algolia (avoids hosted dependency + key management).

**One pass, no second pipeline:** `wbx docs build` = drift-verify against code → render `.html` → tangle `.md` → assemble `llms*.txt`/`sitemap.xml`/schema → build Pagefind.

---

## 5. The docs toolkit / skill — `toolkits/docs/` + `wbx docs *`

The whole pipeline ships as a reusable Workbooks toolkit so any tenant points it at their own code and gets the same Diátaxis skeleton + auto-reference + forced honesty + agent/SEO output for free. This is the canon EXEC-shape home (behavior in the declarative layer, not host `.ex`) and the dogfood the founder wants.

### 5.1 Command surface

```
wbx docs new <section>/<slug>   scaffold an .org page w/ required drawer (status, owner, :SRC:)
wbx docs build                  org → HTML (orgitorial) + .md + sitemap.xml + llms.txt + llms-full.txt + schema + pagefind
wbx docs drift                  KEYSTONE — re-extract every :SRC:/:tangle-from, fail CI on hash mismatch
wbx docs lint                   dead links, missing :STATUS:/:EVIDENCE:, broken :SRC: anchors, schema.org validity
wbx docs untangle               write edited example regions back to docs:anchor:start/end in source
wbx docs serve                  local preview (orgitorial in QuickJS-wasm, no node)
wbx docs publish                render → wrangler pages deploy workbooks-docs (reuses publish.org target props)
```

### 5.2 Ergonomics payoff

Same `org → wbx tangle → CF Pages` loop authors already use for workbooks/toolkits — **zero new mental model, zero node toolchain, runs in-sandbox.** Renderer = `toolkits/orgitorial/` (already QuickJS-wasm-capable). Identity/federation = `toolkits/publish/`. Ship `create-docs` / `docs-authoring` as a skill so any user inherits the identical drift-checked, honesty-gated docs system.

### 5.3 What's reused vs new

- **Reused:** `web/docs/` org tree, `site.org` nav, `toolkits/orgitorial/` renderer + CSS, `runtime/host/publish/site.ex` org→HTML, `wbx tangle`/`lint`, the content-addressed cache, `publish.org` CF target props.
- **New:** `wbx docs drift`/`untangle`/`build` verbs, `wbx schema --json`, the `docs:name:start/end` source anchors, `:SRC:`/`:SRC_HASH:`/`:MATURITY:` drawer schema, `docs/.tangle.lock`, `maturity.json` emitter + `/maturity` page, `.md`/llms/sitemap/schema/pagefind emitters, the CF `_worker.js` md branch, the `cargo xtask gen-docs` + org harvester, the CI Action.

---

## 6. Phased build plan (Part 2)

| Phase | Work |
|---|---|
| **P0 — Name & re-spine** | Move/name the machinery as `toolkits/docs/` + `wbx docs` namespace. Re-spine `web/docs/site.org` to the §1.2 tree (add `deploy/`, `maturity/`; fix `reference/cli.org` `wb`→`wbx`). Add `concepts/*` stubs that LINK to `/learn/*.html` (no duplication). Outcome: correct IA skeleton, existing renderer still builds. |
| **P1 — Drift keystone** | Add the `docs:name:start/end` anchor convention. Implement `wbx schema --json` (clap dump) + `wbx docs drift` (re-extract, hash, `docs/.tangle.lock`). Wire `cargo xtask gen-docs` + org harvester for the table-granularity surfaces (CLI verbs, RCP routes, toolkit catalog, lane matrix, WIT). CI Action beside `runtime-image.yml`. Outcome: reference drift = red build. |
| **P2 — Honesty layer** | Add `:MATURITY:`/`:EVIDENCE:`/`:CAVEAT:`/`:WALL:` drawer schema + fail-closed `wbx docs lint`. Emit committed `maturity.json`. Render inline badges (orgitorial CSS) + the `/maturity` Capability Matrix. Backfill the audit's known over-claims as `partial`/`north-star`/`wall`. Outcome: over-claims cannot ship silently. |
| **P3 — Reference auto-gen complete** | Generate all `reference/*` from code: wbx (clap-markdown), RCP routes (`web.ex`/`public_web.ex` + `@public` allowlist), Dock caps (`policy.ex` tiers), toolkit manifest + #+EXEC shapes, deploy provider matrix, kernel WIT world. Hand-write the medium how-tos for the code-only surfaces (Browser, Nexus internals) with `file:line` anchors. Outcome: every surface covered. |
| **P4 — Agent + SEO** | `.md` sibling emit (badges preserved), `llms.txt`/`llms-full.txt`, auto `sitemap.xml` (git lastmod), `robots.txt`, JSON-LD + canonical + alternate-md + OG in `<head>` (and backfill `/learn`), Pagefind. CF `_worker.js` md branch (ASSET_RE + content negotiation). Outcome: LLM- and search-consumable. |
| **P5 — Toolkit-ize & publish** | Wrap everything behind `wbx docs new/build/serve/publish` as `toolkits/docs/` (`manifest.org` + skills), ship `create-docs` skill. `wbx docs publish` → wrangler to `workbooks-docs`. Document the docs toolkit IN the docs (dogfood). Outcome: reusable, live at `docs.workbooks.sh`. |

Build P0→P2 first: IA + drift gate + honesty gate are the load-bearing differentiators and the lowest-risk to get wrong later. Reference auto-gen, agent/SEO, and toolkit-ization layer on cleanly once the gates exist.

---

## 7. Open questions

- **Anchor granularity vs churn:** `docs:name:start/end` regions in `.ex`/`.rs` add maintenance weight and could be deleted by refactors. Acceptable cost, or lean harder on whole-table `gen-docs` markers and reserve inline anchors for a handful of load-bearing signatures only?
- **`wbx docs build` in-sandbox vs CI:** orgitorial runs in QuickJS-wasm, but Pagefind and `cargo xtask gen-docs` are native build steps. Does the full build run in-sandbox (canon-pure) or is the CF deploy a CI-only path? Likely split: `build`/`serve` in-sandbox, `gen-docs`/pagefind/publish in CI.
- **RCP route introspection:** is there a clean module attribute / router reflection in `web.ex`/`public_web.ex` to harvest routes, or does P3 need a small `Plug.Router` introspection shim added to the runtime?
- **`maturity.json` ownership across surfaces:** capabilities span seven owners; who arbitrates a contested tier (e.g. desktop "UI is a workbook")? Propose: surface `:OWNER:` owns the drawer, but `/maturity` PRs require the owner's review.
- **`/learn` retrofit scope:** adding canonical + JSON-LD + the badge component to ~21 existing hand-rolled HTML pages — do them in the same pass (P4) or as a follow-on? They're not org-sourced, so they need a separate small injector.
- **Versioning trigger:** confirm the first breaking wbx/RCP change is the right moment to introduce `/v1/`, and that path-prefix (not branch-fork) is acceptable to the founder.
- **KEPT-key stripping:** `claims.html#limits` notes the runtime org parser doesn't yet strip `KEPT(k)` fast-select keys — `wbx docs drift`/`lint` must strip them itself until the parser does. Confirm where that lives.

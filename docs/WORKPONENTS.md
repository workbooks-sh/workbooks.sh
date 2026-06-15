# Workponents — the Workbooks web-component SDK

> A themed, framework-agnostic **web-component** library (`<wb-*>` custom elements), organized by
> domain, distributed shadcn-style (a registry you install + own + theme). Used by three consumers
> from one codebase: the **desktop app**, **any workbook** (drop-in HTML, no build), and a **public
> dev-kit**. Synthesized from 9 parallel research briefs, 2026-06-15.

## The thesis

It is **not nine (or fifteen) libraries — it is one substrate surfaced as many domains.** Every
domain's research independently converged on the same spine, which is also why this is *possible*
for us and not for shadcn/Vercel/Liveblocks/Mapbox:

1. **Composition-as-source** — the artifact *is* its declarative org/OQL source. No separate document
   model, no proprietary JSON IR, no export step. Preview ≡ source. (Wavelet's keystone, generalized.)
2. **In-nexus / in-WASM compute** — real engines run in the browser sandbox, so the component that
   *renders* the data also *computes* it. No server round-trip, works offline, ships in one file.
3. **Agent-editable** — because the artifact is byte-addressable source, build-by-talking edits it
   through the same seam a human cursor uses. No "AI mode," no model-format translation.
4. **Framework-agnostic custom elements** — the only UI primitive that runs inside a workbook (plain
   HTML) *and* the desktop (Svelte hosts them trivially) *and* a public page.
5. **One element, swap provider** — each element resolves capabilities through the Host/Dock membrane
   (`local` / `runtime` over RCP / `kernel` oql.wasm), so the same `<wb-table>` runs in-WASM locally
   or on the runtime tier for huge data, no code fork (platform-model canon).

**The shared engines** (the reason the domains compose instead of duplicating):
- **SQLite** — the data engine behind `tables`, `data-viz`, `maps`, `records`, and `search`. A workbook already SHIPS SQLite (its VFS — `Workbooks.VFS`), so the data tier rides it, NOT a bolted-on DuckDB. Host-resolved per context: native `exqlite` over the runtime (Dock `vfs-query`, durable/server-side — "the unbundling"), in-page **sqlite-wasm** (~1.3MB) when static, or an in-JS subset floor. One SQL dialect everywhere. (DuckDB-wasm was evaluated and dropped: 34MB, divergent dialect, redundant.)
- **Wavelet render-core + `wb_encode.wasm`** — behind `video`, `presentation` (a deck = a wavelet timeline with discrete keyframe bands → "export to video" is free), and `audio`.
- **The OQL/org kernel** (`runtime/kernel`, `oql.wasm`) — behind `docs`, `ai` (conversation-as-source), and the composition-as-source model everywhere.
- **RCP + the BEAM runtime** — behind `live` (Phoenix Presence/PubSub = realtime with no provisioned backend) and every element's provider seam.
- **The compiler lane** (clang/rustc/zig/go/StarlingMonkey → wasm) — behind `code` (real in-sandbox eval) and the build-by-talking loop.

Cross-domain composition is the payoff: a map's `<wb-geo-query>` feeds a `<wb-table>` and a
`<wb-chart>` off one engine; a `<wb-gen-block>` the AI writes is the same `#+EXEC` block the doc
renders; a deck drops a live `<wb-chart>` on a slide and exports the whole thing to MP4.

## Pillar: Design System & Theming + Validation (shadcn-grade)

Workbooks **and** workponents are one cohesively design-managed system, to shadcn's standard. This is
a foundational pillar, not a coat of paint.

- **Token system** — every element styles ONLY from CSS custom properties; one token set themes all
  domains *and* the workbook artifacts. No hardcoded values.
- **Theme registry + presets** — installable/forkable themes (the `components.json` + theme-generator
  model), light/dark, and **per-workspace brand themes** as first-class (the demo brands — Signal vs
  UGC Pro vs Brand Nana — are already this pattern).
- **Variant API** — typed variants / sizes / tones as attributes (shadcn's `cva` discipline), so a
  `wb-button` or `wb-chart` is consistent everywhere.
- **Theme-as-source** — a theme is itself a declarative token spec, agent-editable ("warmer, more
  rounded"). Composition-as-source applied to design.
- **Validation, two senses:**
  - *Design conformance* — a design-lint: elements must use tokens (no off-system values), pass a11y,
    use valid variants. The system can't drift — the discipline that makes shadcn feel unified.
  - *Data/form validation* — the `forms`/`records` schema-as-source validation, run **in-WASM** before
    any server round-trip.

## The domains

Each is a wavelet-level reinvention, not a widget pack. Status: ✅ substrate exists (mostly surfacing) ·
◐ partial · ○ greenfield.

| Domain | The reinvention (one line) | Killer element | Engine | Status |
|---|---|---|---|---|
| **video** | Editing in-WASM; composition = source; player IS renderer; encode in-guest (the exemplar) | `<wb-video>` / wavelet | render-core | ✅ shipped |
| **ai** | Conversation-as-source: agent edits a living org artifact; generated UI = in-nexus `#+EXEC` blocks, not a JSON IR | `<wb-gen-block>` | OQL kernel | ✅ prototype in `desktop/src/lib/chat/*` |
| **docs** | The doc IS its org source, directly editable in the rendered view (no second model); live computed cells | `<wb-doc-cell>` | OQL kernel | ✅ OQL renderer exists |
| **git** | Mechanistic, system-managed VC: no git verbs surfaced; jj op-log = undo-anything; semantic in-WASM diffs; josh subtree share | `<wb-history-graph>` / `<wb-diff>` | jj/josh + in-WASM diff | ✅ backends headless (`history.ex`/`jj.ex`/`draft.ex`) |
| **tables** | The table IS a query over the workbook's SQLite; sort/filter/pivot push to SQL; runtime VFS or in-page sqlite-wasm | `<wb-table>` | SQLite | ✅ done |
| **data-viz** | Composition-as-source charts; aggregation computed in SQL on the shared SQLite engine; a live query you can talk to | `<wb-chart>` / `<wb-spark>` / `<wb-metric>` | SQLite | ✅ done |
| **maps** | Composition-as-source maps; geo compute in SQL; zero-dep themed projection standalone, PMTiles tiles via Host | `<wb-map>` | SQLite (+ PMTiles via Host) | ✅ done |
| **presentation** | A deck = a wavelet timeline (keyframe bands); shares the render-core → export-to-video free; live blocks on slides | `<wb-deck>` / `<wb-slide>` | render-core | ◐ rides wavelet |
| **live** | Realtime is a routing config: presence/pubsub free off the BEAM over RCP; CRDT opt-in per workbook; voice the one keyed exception | `<wb-room>` / `<wb-presence>` | RCP + BEAM | ◐ RCP exists |
| **forms** | Schema-and-validation-as-source: fields/types/rules ARE OQL records driving form + table + DB + API; validate in-WASM | `<wb-form>` / `<wb-field>` | OQL kernel | ○ |
| **records/CRM** | Entity views as queries over the shared SQLite engine; master-detail; typed values; Host write-back | `<wb-record>` / `<wb-record-list>` | SQLite | ✅ done |
| **search/command** | ⌘K over the live OQL graph + in-WASM FTS5/vector; actions = agent-invokable Dock capabilities | `<wb-command>` | in-WASM FTS | ○ |
| **auth** | Gating reveals/withholds *capabilities* (the Dock grant model), not booleans; WorkOS/Clerk plug one Host seam | `<wb-gate>` / `<wb-user>` | Dock | ○ |
| **code** | Real in-sandbox eval via the compiler lane (C/Rust/Zig/Go/JS); editor edits composition-as-source live | `<wb-repl>` / `<wb-editor>` | compiler lane | ○ (lane exists) |
| **files** | Content-addressed nexus storage + in-WASM preview/transcode (rides wavelet's ffmpeg); files = OQL records | `<wb-file>` / `<wb-drive>` | wavelet encode | ○ |

Next tier (high ceiling, larger build): **automation/workflows** (`<wb-flow>` — steps = agent-runnable
Dock capabilities; fold its visual layer into…) and **whiteboard/canvas** (`<wb-canvas>` — diagram = an
executable OQL graph). **Wrap, don't reinvent** (broker-bound, no in-WASM 10×): payments, comms,
scheduling, 3d.

## Workponents × Toolkits (the integration)

Distinct layers, deeply integrated through shared seams — **not fused** (fusion kills reusability and
the headless/agent path). Both are *loaded* artifacts (not host engines).

- **Toolkit = capability / compute / behavior** (what runs: CLIs, the `#+EXEC` shapes, kernel
  renderers, in-WASM engines — brokered via the Dock, runnable headless with no UI).
- **Workponent = the themed UI surface** (`<wb-*>` elements that render + let you interact).

The five integration points:

1. **Declared capabilities, one Dock seam.** A workponent declares the toolkits it needs (`<wb-table>`
   → `needs: sqlite`); the Host/Dock provisions them with the same grant model toolkits use, resolving
   `local`/`runtime`/`kernel` per platform-model — no second capability mechanism.
2. **Toolkits stay shared + headless — one engine, many views.** One SQLite engine (the workbook's VFS)
   backs `wb-table`, `wb-chart`, `wb-map`, `wb-record`, `wb-search`. A workponent *consumes* a toolkit,
   never *contains* one (else you duplicate the engine and lose the agent's no-UI invocation path).
3. **The `component` EXEC shape is the bridge** (the "renderer = kernel-shape toolkits" idea, concrete):
   a workponent is the **curated, themed, registry-distributed tier** of the component shape; an author's
   bespoke `#+EXEC component` is the **open tier**. Same kernel render path, same Dock seam.
4. **One registry, one install** — installing `<wb-table>` pulls its declared capability (SQLite)
   automatically; the shadcn-style install handles both layers. One dev-kit surface, not two.
5. **One contract for authors and agents** — capability via the Dock, theme via the token system. The
   build-by-talking loop is identical whether the agent emits a `<wb-chart>` or hand-rolls a component.

Net: **workponents are the themed UI tier of the toolkit substrate.**

## Build roadmap

- **Phase 0 — Scaffold.** The package; the **theming layer** (tokens + registry + variant API + theme-lint);
  the shadcn-style install/registry; custom-element conventions; the Host/Dock provider seam shared by all
  elements. Decide the render tier story (Blitz CSS-only vs JS-capable player vs desktop webview).
- **Phase 1 — Seeds (substrate exists; mostly surfacing).** `video` (wrap wavelet) · `ai` (port the chat
  elements) · `docs` (the OQL renderer) · `git` (surface the headless `history/jj/draft` backends). Fastest
  wins, proves the conventions.
- **Phase 2 — The data trio (done).** `tables` → `data-viz` → `maps`. One SQLite engine, three surfaces;
  the SQLite seam (runtime VFS / in-page sqlite-wasm / floor) built once.
- **Phase 3 — The no-code essentials (done).** `forms` · `records/CRM` · `search/command` · `auth`. The floor
  every app needs; `records`/`search` ride the SQLite engine, `forms` owns the shared validate layer.
- **Phase 4 — Composers.** `presentation` (rides wavelet) · `live` (rides RCP) · `code` (compiler lane) ·
  `files` (wavelet encode).
- **Later.** `automation` + `whiteboard`; wrap payments/comms/scheduling/3d.

## Recurring hard parts (flagged across briefs)

- **Render tier** — wavelet's render path is CSS-only (no JS in Blitz); interactive elements need the
  JS-capable tier while deterministic render/export uses the CSS-clock path. Reconciling these is the core
  tension for `video`/`presentation`/animated UI.
- **In-WASM bundle weight** — sqlite-wasm (~1.3MB) and render-core are multi-MB; lazy-load per the `oql.ts`
  pattern (sqlite-wasm boots only when there's no runtime tier, and only on first query). DuckDB (34MB) was
  rejected for exactly this reason — SQLite is an order of magnitude smaller and already shipped.
- **Reactive graph** — incremental recalc spanning SQL views + scalar cells (`tables`/`docs`); clean-room
  it (avoid GPLv3 HyperFormula), scope to view-level + UDF cells.
- **Agent-block sandboxing** — agent-authored `<wb-gen-block>` runs untrusted output; double-iframe / kernel
  isolation; never execute model output directly (the `ChatComponent.svelte` model).
- **Editable-rows writeback** — in-page sqlite-wasm edits are local/ephemeral; durable writes route through
  the runtime's native SQLite VFS (Host write seam). Elements reflect `engine.writable()`, never assume.
- **VFS travels with the file (data-leak guardrail)** — a static workbook embeds its SQLite VFS in the HTML,
  so the `workspace` volume is PUBLIC-to-recipient; durable/private data belongs server-side (runtime VFS /
  Postgres), never authored into an embedded volume. See `WORKBOOK-DATA-LEAK-AUDIT.md`.
- **Keyed exceptions (be honest)** — voice needs an STT/TTS key + media transport; map basemap *pixels*
  still need PMTiles you host or brokered tiles; payments are a trusted host broker. Disclose via the
  capability handshake so elements degrade cleanly.

## References

Per-domain briefs (this session's research) cover state-of-the-art + the killer demo for each. Ties to
`platform-model.md` (the Host/Dock seam), the collaborative-workspaces direction (`git`/`live`),
`wavelet` (`video`/`presentation`/`files`/`audio`), and the OQL kernel (`docs`/`ai`/`records`/`forms`).

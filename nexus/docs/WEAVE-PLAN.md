# Weave — the complete render plan (the contract)

**Goal:** weave produces a real, rendering **HTML workbook** across every compile lane and data
mode, adversarially tested, no holes, no stubs. Execute end to end (see the AUTONOMY MANDATE in
AGENTS.md). Each step: build green (`cd nexus && mix compile` + `mix test --exclude compiler`;
`--only compiler` when a lane changes), commit, push. Pick up the next step on every loop fire.

## The model (settle this, then build to it)

A **workbook IS an HTML file.** It renders client-side because browsers render HTML — nothing
custom. The pluggable part is the **data layer**, same API across three modes:

1. **Baked** (default, local, zero-runtime) — weave queries the Store at build time and bakes the
   rows straight into the HTML. A double-clickable file. This is the original point of workbooks.
2. **Local-live** (optional SQLite) — the HTML ships with a SQLite the page queries *in the browser*
   via wasm SQLite (wa-sqlite/sql.js). Fully local, live, no server.
3. **Server** — the HTML fetches from a nexus server's Store HTTP endpoint. Cloud/shared.

One client-side data API (`nexus.data`) with three backends behind it — the browser mirror of the
`Nexus.Store` seam. SSR (server pre-renders) is just mode 1 done at request time instead of build
time. Units (rust/c/zig → wasm components) render their **output** (run at weave/serve time, baked)
and can later run client-side via browser-wasm; baked-output first.

---

## Phase 0 — integrate the OCI image work
- Fold the background agent's worktree commit (release config, `Nexus.Application`, Dockerfile,
  `deploy/build.sh`, `docs/OCI-IMAGE.md`) into the branch. Resolve the `mix.exs` overlap (exqlite
  dep + releases block). `mix compile` + `mix release nexus` boot path green. Commit.

## Phase 1 — render-aware weave: directives → views (baked data)
- `Nexus.Render` (or extend Weave): turn parsed directives into views instead of `<pre>`.
- `show Resource` → an HTML `<table>` of the resource's Store rows, columns from `__fields__`,
  **XSS-escaped**. Empty/absent resource → a graceful empty-state, never a crash.
- `data Name from: Resource` (and the `data`/`query` decls) → the same baked view, named.
- Keep prose/markdown/lists/unit blocks working.
- Tests: show with rows, show with no rows, XSS in a cell escaped, unknown resource handled.

## Phase 2 — the index as composition root
- `index.work` drives the page: title, ordering, a layout shell. The other files compose under it.
- A `route`/section model so a multi-file workbook reads as one coherent page (not just stacked
  file sections). Tests: a 3-file workbook composes in index order with one shell.

## Phase 3 — units render across ALL lanes (rust / c / zig)
- A unit whose output appears in the page: weave runs the unit on wasmex (Sandbox) at build time
  and bakes the result. e.g. a `c`/`rust`/`zig` unit `summary() -> string` → its text in the page.
- Prove ONE worked example per lane (rust, c, zig) end to end in a workbook → woven HTML.
- Tests (tagged :compiler): each lane's unit output lands in the woven HTML.

## Phase 4 — the client-side data API (`nexus.data`) + the three backends
- A small JS shim baked into the woven HTML exposing `nexus.data.all("Resource")` etc. — the
  browser mirror of `Nexus.Store`.
- **Baked backend:** data is inlined as a JSON island (`<script type="application/nexus-data">`);
  `nexus.data` reads it. (JSON here is a generated data payload at a boundary — allowed.)
- **Local-live backend:** wire wasm SQLite (wa-sqlite) so `nexus.data` queries a shipped SQLite in
  the browser. Prove a query returns rows client-side.
- **Server backend:** `nexus.data` falls back to `fetch('/data/Resource')`. Build the matching
  nexus HTTP endpoint (a thin Plug/cowboy server over `Nexus.Store`).
- Same three behind one API; the workbook author writes `show`/`nexus.data` once, the mode is a
  weave/deploy flag. Tests: baked island parsed, server endpoint returns rows, (local-live proven).

## Phase 5 — the served nexus (SSR live) wired to deploy
- Request-time render = Phase 1 against the live Store. The nexus server serves a workbook folder.
- Wire it so `Nexus.Deploy.local` boots a nexus that serves a workbook over HTTP (port 4000).
- Test: the server renders a workbook with live data over HTTP.

## Phase 6 — adversarial testing (the untangling)
- Malformed `.work` (unclosed blocks, bad directives) → graceful, never crash the weave.
- XSS payloads in data/prose → escaped everywhere.
- A unit that traps/fails at build → the page degrades, reports it, keeps rendering the rest.
- Huge data (1000s of rows) → bounded/paginated, not a 50MB page.
- Every lane × every data mode × empty/full/malformed. A dedicated `weave_adversarial_test.exs`.
- An ungranted cap inside a render unit → blocked (Audit), surfaced.

## Phase 7 — the complete living demo + docs
- One demo workbook exercising everything: a resource, `show`, a unit per lane, all three data
  modes documented, woven to HTML you can open. Update `examples/`.
- `docs/WEAVE.md` — the render model, the three data modes, how to serve, how to ship local-only.

## Done when
weave renders real HTML workbooks across all lanes and all three data modes, served *and* local,
adversarially tested, demo + docs shipped, every suite green, all pushed. Then — and only then —
the runtime's render path can be sunset.

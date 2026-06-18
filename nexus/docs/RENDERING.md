# Rendering — CSR vs SSR: capabilities, security, edges

Two ways to run a workbook, one render and one client API (`nexus.data`). Both are locked +
browser-proven from nexus.

- **CSR (file)** — `weave/1` → an `.html` opened directly (`file://`). Renders client-side, data
  baked + IndexedDB. Offline, local-only, no server. `mix run -e 'File.write!("wb.html", Nexus.Weave.weave(root))'`.
- **SSR (served)** — `mix nexus.serve PATH` → `Nexus.Server`. `GET /` SSRs (cached by .work mtime —
  units compile once), `GET /data/:resource` is live. The page is `live: true` so the client
  prefers fresh `/data`.

## Capability matrix

| Capability | CSR (file, local) | SSR (served nexus) |
|---|---|---|
| Prose / structure / markdown | ✓ | ✓ |
| `show Resource` data table | ✓ baked (static) | ✓ live from the Store |
| Mutable local data | ✓ IndexedDB (`nexus.data.create`) | n/a (writes go to the server Store) |
| `show Unit` compute output | ✓ baked at weave time (static) | ✓ SSR'd; recomputed on .work change |
| Live / shared / multi-client data | ✗ (one local copy) | ✓ via `/data` |
| Durable mutations | local (IndexedDB) | server Store (ETS / SQLite / Postgres) |
| Host capabilities (net/llm/kv via the Dock) | ✗ (no host) | ✓ (server runs units under the Dock) |
| Auth / access control | ✗ | ✓ (the server can gate — see Wary) |
| Offline | ✓ | ✗ (needs the server; client falls back to baked if reachable-then-lost) |

The rule of thumb: **CSR is the default and the floor** (a workbook is an HTML file); **SSR adds
live data, shared state, host capabilities, and access control.** Same workbook, same `nexus.data`.

## Security — handled vs. be wary

**Handled now:**
- **XSS** — every interpolated value is escaped (`&`, `<`, `>`, `"`); the baked JSON island is
  `html_safe`-encoded so a `</script>` in data can't break out. (Tests cover both.)
- **Capability audit** — a `show <Unit>` whose unit calls an **ungranted** cap is blocked by
  `Nexus.Audit` *before* it compiles/runs. The grant is the contract.
- **Sandbox** — server-run units execute on wasmex (wasmtime isolation); host reach is only the
  granted Dock caps. `fetch` is **SSRF-brokered** (loopback/private/link-local blocked).
- **DoS bounds** — the SSR shell is **cached** (no per-request unit recompile); huge resources are
  **capped** at 500 rows (table + island), so data size can't blow the page.

**Be wary (open before multi-tenant production):**
- **`/data` is unauthenticated + unscoped** — it returns *all* rows of a resource. Fine for a
  single-tenant/local dev server; **a multi-user deployment must add auth + per-tenant filtering**
  in front of `/data` (and any future write endpoint). This is the #1 thing to gate.
- **Baked data is exposed in the file** — a CSR file contains every baked row. **Never bake
  sensitive data into a shipped file**; bake only public data, serve the rest (SSR + auth).
- **First-weave cost** — a workbook with many units pays a one-time compile on first request /
  after a `.work` change (cache miss). Acceptable, but a hostile workbook with hundreds of units
  could make that slow; treat workbook upload as a trusted/authored action, not anonymous input.
- **No write endpoint yet** — `/data` is read-only. A server write path must run `Store.create`
  (which validates shape + enums) and add auth; don't accept raw writes.

## Validation

- **Shape** — `Nexus.Resource.validate/2`: rejects unknown fields and enum values outside the
  declared cases. Enforced on every `Store.create` (ETS and SQLite backends both).
- **Caps** — `Nexus.Audit`: a unit may only use host caps it grants.
- **Output** — XSS escaping + the 500-row cap.

## Edge cases (all handled, tested)

- Malformed / garbage `.work` → renders the shell, never crashes.
- A unit that fails/traps at render → degrades to a notice, keeps rendering the rest.
- Empty resource → graceful empty-state; unknown resource → a visible notice.
- Offline served page → `nexus.data` falls back to baked/local.
- Data changed after the SSR shell was cached → `/data` is live and reflects it (server mode).
- `file://` origin isolation → each woven file's IndexedDB is its own origin (no cross-file leak).

## Bottom line

CSR works as a local HTML file (offline, baked + mutable-local); SSR works from a served nexus
(live data, host caps, cacheable). Both proven in a real browser. The one gate before
multi-tenant production is **auth + tenant-scoping on `/data`** — everything else (XSS, sandbox,
SSRF, validation, DoS bounds, edge handling) is in place.

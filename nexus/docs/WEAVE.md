# Weave — the render model

A **workbook is an HTML file** (or a folder of `.work` files woven into one). The browser renders
it — that's just HTML, nothing custom. The only pluggable part is the **data layer**, behind one
client API. `Nexus.Weave.weave/1` produces the file; `Nexus.Server` serves it live.

## What renders

| In a `.work` file | Becomes |
|---|---|
| markdown prose (`#`, `**b**`, `*i*`, `` `code` ``, `[t](url)`, `- ` lists) | HTML, inline-formatted |
| `resource Name do … end` | a typed struct + a Store-backed shape (the data) |
| `show <Resource>` | a live `<table>` of that resource's Store rows (columns from the shape) |
| `show <Unit>` (a `rust`/`c`/`zig` unit) | the unit is compiled to wasm, its no-arg `render()` runs on wasmex at build time, the result is baked in |
| `index.work` | the composition root — leads, titles the page; a multi-file workbook gets a nav |

Every interpolated value is XSS-escaped; a huge resource is capped (table + island) at 500 rows;
a `show <Unit>` whose unit calls an **ungranted** cap is blocked by `Nexus.Audit` before it runs.

## The data layer — one API, three backends

The woven page exposes `window.nexus.data` — the browser mirror of `Nexus.Store`:

```js
await nexus.data.all("Product")          // read rows
await nexus.data.create("Product", row)  // add a row (local-live backend)
```

Behind it, three interchangeable backends — the workbook author writes `show`/`nexus.data` once:

1. **Baked** (default, local, zero-runtime) — rows are inlined as an html-safe JSON island the
   page reads. Double-click the file; it works offline with its data. This is the original point
   of workbooks: a self-contained local HTML file.
2. **Local-live** (mutable, local) — `create()` persists to **IndexedDB**, survives reloads, no
   server. `all()` = baked ∪ local. Local-only *and* mutable. (A wasm-SQLite engine could swap in
   here behind the same API if SQL is wanted; IndexedDB is the browser-native default.)
3. **Server** — when there is no local data, `nexus.data` falls back to `GET /data/<Resource>` on a
   served nexus. Cloud/shared; the server data layer is `Nexus.Store` (ETS / SQLite / Postgres).

`all()` resolves baked ∪ local first, server last — so the *same* page is fully local by default
and transparently picks up a server when one is there.

## Serving it live

```elixir
Nexus.Server.start_link(root: "examples/store", port: 4000)
# GET /                → the workbook, SSR'd with live Store data
# GET /data/:resource  → that resource's rows as JSON (the server backend)
```

SSR is just the baked render done at request time against the live Store. The local file and the
served nexus share one render and one client API; only the data backend differs.

## Local-only (the default)

```elixir
File.write!("store.html", Nexus.Weave.weave("examples/store"))
# open store.html in any browser — no server, data baked in, nexus.data works
```

That's the whole promise: a workbook you can email, that renders and carries its data anywhere,
and that scales up to a live server or a mutable local store without changing the workbook.

# Host-Brokered Capabilities — reference (campaign deliverable, 2026-06-12)

The pattern: a wasm guest stays sandboxed; the **host performs the privileged op** behind a mediated,
Policy-gated `env.*` import (the Dock membrane). Five capabilities, each with the same cadence —
**default-deny, scoped, quota'd, audit-logged, adversarially tested, offline-e2e-proven** (where the dev env
allows). Guests reach these via `RustDock`/`JsDock` (env imports gated by the profile's caps); inbound
serving is via `ServeBroker`.

## The import surface (ABI)

| Import | Signature `-> i32` | Cap gate | Broker | Notes |
|---|---|---|---|---|
| `host_http_get` | `(url_ptr,url_len, out_ptr,out_cap)` → body len / -1 | `net`/`browse` | `NetGuard` | SSRF floor + redirect re-check + allow-list + audit |
| `host_http_get_many` | newline URLs in → `[count][len,body]*` | `net`/`browse` | `NetGuard` | concurrent egress |
| `host_exec` | `(req_ptr,req_len, out_ptr,out_cap)` → out len / -1 | `commands` | `ExecBroker` | runs a REGISTERED wasm cmd, sandboxed; req = `parse_request` LE format; no injection (structural argv) |
| `host_parallel_map` | `(req,out)` → `[n][(len,-1=err)(body)]*` | `commands` | `ParallelBroker` | fan a cmd over N inputs CONCURRENTLY (BEAM); fan-out + concurrency caps |
| `host_kv_put` | `(key_ptr,key_len, val_ptr,val_len)` → 0 / -1 | `vfs` | `StorageBroker` | DURABLE, per-TENANT (tenant from Dock, not guest); size + key-count quotas |
| `host_kv_get` | `(key_ptr,key_len, out_ptr,out_cap)` → val len / -1 | `vfs` | `StorageBroker` | tenant-isolated read |
| `host_request_get` | `(out_ptr,out_cap)` → req len | (serve instance) | `ServeBroker` | inbound: fetch the current request bytes |
| `host_response_set` | `(ptr,len)` → 0 | (serve instance) | `ServeBroker` | inbound: return the response bytes (size-capped) |
| ambient: `host_now`, `host_log`; vfs: `host_vfs_read/write` | | always / `vfs` | — | clock/log; ephemeral per-instance KV |

Both `rust_dock` and `js_dock` expose the same `host_*` surface (gated identically by the profile's caps).

## The five capabilities

1. **Networking egress** — `NetGuard` (host/net_guard.ex). The deny side is comprehensively secured and
   red-team proven: SSRF floor on BOTH paths (NIF `socket_addr_check`+`send_request` for wasi; Elixir
   `NetGuard.get` for the mediated `host_http_get`), obfuscation defense (decimal/hex/octal/short IP,
   userinfo@, IPv4-mapped — 12-case suite), redirect-to-internal per-hop re-check, scoped host allow-list,
   audit log. **Functional reachability + the standard-tool wasi-seam are env/refactor-gated** (wb-0beq async
   engine refactor + wb-k2im internet env) — the 323-tool reclamation waits there; not false-claimed.
2. **Exec** — `ExecBroker` (host/exec_broker.ex). Broker a guest's exec to the 32 sandboxed wasm commands;
   default-deny, registered-only, no OS exec, structural argv (no injection), bounded nesting, output cap,
   audit. Guest e2e-proven.
3. **Durable storage** — `StorageBroker` (+ `.Server`, host/storage_broker.ex). Persistent sqlite-backed
   per-tenant KV; tenant isolation, size/key quotas, durable across runs. Guest e2e-proven (both docks).
4. **Data-parallelism** — `ParallelBroker` (host/parallel_broker.ex). Run a cmd over N inputs concurrently
   across BEAM processes (each a fresh ExecBroker sandbox); default-deny, fan-out + concurrency caps. Guest
   e2e-proven (both docks).
5. **Inbound HTTP serving** — `ServeBroker` (+ `.Plug`, host/serve_broker.ex). Host owns the socket; a guest
   handles requests sandboxed (persistent instance re-entered per request; request/response via the two
   serve imports + an ETS channel). Full HTTP marshaling (forward request headers; guest sets status +
   headers + body). Guest e2e-proven over a REAL Bandit listener.

## Validation

All broker unit/hermetic suites green together (34 tests): `net_guard`, `exec_broker`, `storage_broker`,
`parallel_broker`, `serve_broker`. Guest e2e proofs (`@tag :build`, real Rust/C guests) for exec, storage,
parallel, and serve. Dock additions regression-free (`js_dock_test` green). Networking deny-side has its own
red-team suite; its egress reachability is the only env-gated remainder.

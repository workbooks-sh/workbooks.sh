# Host-Brokered Capabilities — reference (campaign deliverable, 2026-06-12)

The pattern: a wasm guest stays sandboxed; the **host performs the privileged op** behind a mediated,
Policy-gated `env.*` import (the Dock membrane). Ten capabilities, each with the same cadence —
**default-deny, scoped, quota'd, audit-logged, mid-flight-revocable, adversarially tested, offline-e2e-proven** (where the dev env
allows). Guests reach these via `RustDock`/`JsDock` (env imports gated by the profile's caps); inbound
serving is via `ServeBroker`.

## The import surface (ABI)

| Import | Signature `-> i32` | Cap gate | Broker | Notes |
|---|---|---|---|---|
| `host_http_get` | `(url_ptr,url_len, out_ptr,out_cap)` → body len / -1 | `net`/`browse` | `NetGuard` | SSRF floor + redirect re-check + allow-list + audit |
| `host_http_get_many` | newline URLs in → `[count][len,body]*` | `net`/`browse` | `NetGuard` | concurrent egress |
| `host_exec` | `(req_ptr,req_len, out_ptr,out_cap)` → out len / -1 | `exec` | `ExecBroker` | runs a REGISTERED wasm cmd, sandboxed; req = `parse_request` LE format; no injection (structural argv) |
| `host_parallel_map` | `(req,out)` → `[n][(len,-1=err)(body)]*` | `exec` | `ParallelBroker` | fan a cmd over N inputs CONCURRENTLY (BEAM); fan-out + concurrency caps |
| `host_kv_put` | `(key_ptr,key_len, val_ptr,val_len)` → 0 / -1 | `kv` | `StorageBroker` | DURABLE, per-TENANT (tenant from Dock, not guest); size + key-count quotas |
| `host_kv_get` | `(key_ptr,key_len, out_ptr,out_cap)` → val len / -1 | `kv` | `StorageBroker` | tenant-isolated read |
| `host_sign` | `(name,data, out)` → sig len / -1 | `secrets` | `SecretBroker` | HMAC-SHA256 data with a host-held per-tenant secret; guest gets the SIGNATURE, never the key |
| `host_publish` | `(topic, msg)` → 0 / -1 | `queue` | `QueueBroker` | enqueue to a per-tenant topic |
| `host_poll` | `(topic, out)` → msg len / -1 | `queue` | `QueueBroker` | dequeue oldest (FIFO) — inter-guest coordination |
| `host_tcp` (planned import) | `(host,port,req, out)` → resp len / -1 | `tcp` | `TcpBroker` | brokered raw-TCP request/response; RESOLVE-THEN-PIN (DNS-rebinding defense) + SSRF + rate/revoke |
| `host_udp` | `(host,port,dgram, out)` → reply len / -1 | `udp` | `UdpBroker` | brokered UDP send/recv-one (DNS/NTP/STUN); resolve-then-pin + SSRF + rate/revoke |
| `host_tls` | `(host,port,req, out)` → reply len / -1 | `tls` | `TlsBroker` | brokered TLS request/response (HTTPS, TLS line protocols) for crypto-less guests; host does the cert-verified handshake; resolve-then-pin + SSRF + rate/revoke |
| `host_request_get` | `(out_ptr,out_cap)` → req len | (serve instance) | `ServeBroker` | inbound: fetch the current request bytes |
| `host_response_set` | `(ptr,len)` → 0 | (serve instance) | `ServeBroker` | inbound: return the response bytes (size-capped) |
| ambient: `host_now`, `host_log`; vfs: `host_vfs_read/write` | | always / `vfs` | — | clock/log; ephemeral per-instance KV |

Both `rust_dock` and `js_dock` expose the same `host_*` surface (gated identically by the profile's caps).

## The ten capabilities

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
10. **TLS request/response** — `TlsBroker` (host/tls_broker.ex). Brokered TLS for crypto-less guests (HTTPS / TLS line protocols) — host does the cert-verified (verify_peer + system trust store, SNI=hostname), resolve-then-pinned handshake. Real HTTPS-over-TLS e2e-proven. + rate/revoke/size-cap.
9. **UDP send/recv** — `UdpBroker` (host/udp_broker.ex). Brokered one-shot UDP datagram + reply (DNS/NTP/STUN) — host opens the socket to a resolve-then-pinned, SSRF-checked IP. Real DNS-over-UDP e2e-proven. + rate/revoke/size-cap.
8. **Raw-TCP request/response** — `TcpBroker` (host/tcp_broker.ex). The host opens the TCP connection (RESOLVE-THEN-PIN: resolves once, refuses internal, connects to the PINNED IP — closing the DNS-rebinding window the TLS http path can't), sends the request bytes, reads the reply, closes. Covers line protocols (HTTP/1, Redis) for hand-written guests. SSRF + revocation + rate + size-cap. Real public-TCP e2e-proven.
7. **Inter-guest message queue** — `QueueBroker` (host/queue_broker.ex). Per-tenant topics; a guest publishes, another polls (FIFO). Lets sandboxed guests hand work to each other (producer/consumer, events) WITHOUT shared memory. Tenant-isolated + depth-capped + revocable. Inter-guest e2e-proven (a producer guest -> a separate consumer guest).
6. **Secrets (host holds creds)** — `SecretBroker` (host/secret_broker.ex). The host holds named per-tenant secrets; a guest can SIGN data (HMAC-SHA256) with a named secret but can NEVER read its value (no read op exists). Tenant-isolated + revocable. Lets a sandboxed guest authenticate webhooks/APIs/JWTs without possessing the credential. Guest e2e-proven.
5. **Inbound HTTP serving** — `ServeBroker` (+ `.Plug`, host/serve_broker.ex). Host owns the socket; a guest
   handles requests sandboxed (persistent instance re-entered per request; request/response via the two
   serve imports + an ETS channel). Full HTTP marshaling (forward request headers; guest sets status +
   headers + body). Guest e2e-proven over a REAL Bandit listener.

## Validation

All broker unit/hermetic suites green together (34 tests): `net_guard`, `exec_broker`, `storage_broker`,
`parallel_broker`, `serve_broker`. Guest e2e proofs (`@tag :build`, real Rust/C guests) for exec, storage,
parallel, and serve. Dock additions regression-free (`js_dock_test` green). Networking deny-side has its own
red-team suite; its egress reachability is the only env-gated remainder.

## Security audit (iters 53–56) — verdict: SOUND

The brokered-capability surface was systematically audited. Gaps found are fixed; the rest is verified clean
and test-guarded.

**Gaps found + fixed:**
- iter48 — inbound serve concurrency race (ETS req/resp channel under concurrent dispatch) → per-serve_id atomic lock.
- iter53 — host_http_get_many had no batch-size cap (request amplification) → @max_http_batch 64.
- iter54 — the rate quota was BUILT BUT LATENT (docks never passed :rate) → RateLimiter.default_quota() floor wired into all 5 volume-DoS brokers (net/exec/tcp/udp/tls).

**Verified clean (test-guarded):**
- DoS cadence per surface — RATE floor (volume: network/exec, 2000/s per tenant) + RESOURCE caps (growth:
  queue depth 1000, storage 1MB value / 10k keys) + no-read (secret) + fan-out cap (parallel @max_inputs 1024).
  Rate floor deliberately NOT on the fast growth-DoS brokers (would harm legit µs-ops; caps are the right control).
- SSRF + resolve-then-PIN on ALL FIVE egress paths (host_http_get, wasi-http, wasi-sockets, TcpBroker, UdpBroker, TlsBroker).
- Red-team obfuscation (IP-literals/IPv6/decimal/hex/octal/userinfo@/v4-mapped/redirect/rebinding/exfil) proven HOLISTICALLY against a live guest.
- Tenant isolation — per-tenant namespacing + SQL `tenant=?1` scoping; tested for storage + queue.
- No-injection — exec argv is structural (`"; rm -rf /"` is a literal arg); tested.
- Parameterized SQL throughout (?1/?2 + bind) — no injection.
- Revocation — broadly wired (every main broker), mid-flight.

**Remaining frontier:** the inbound STANDARD-component seam (wb-py4k) — a focused-session NIF (sync bindgen!
proxy + resource-lowering). The hand-written serve_broker covers the inbound capability today (DoS-hardened +
concurrency-correct).

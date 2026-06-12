# Host-Brokered Capabilities Campaign — the next frontier

**Mission:** extend the capability-lane philosophy from BUILD-time to RUN-time. The host (BEAM) performs
the privileged primitive; the guest stays sandboxed; the Dock membrane mediates under explicit Policy.
Keystone = host-brokered **networking**, done *securely*. Then re-run the 323 "impossible" items and
reclaim every one that was only blocked by the no-broker assumption. Then the next stones. Keep pushing.

> Read this first every turn. Execute the NEXT bounded step in the WORK QUEUE. Security-adversarially
> test every step. mix compile + tests green before commit. Push working increments. Update STATE.
> Never run real OS network/exec OUTSIDE the brokered + Policy-gated path. If blocked, file bd + move on.

## GROUND TRUTH (confirmed 2026-06-12)

What already EXISTS (do not reinvent):
- `host/rust_dock.ex` — `host_http_get` / `host_http_get_many` custom imports. Host reads URL from wasm
  mem → `:httpc.request` → writes bytes back. _many = concurrent via Task.async_stream (BEAM parallelism).
  MEDIATED (host sees the URL) but only for Rust guests written to call it.
- `host/js_dock.ex` — `host_http_get` exposed to JS as `Javy.Net`, gated by `Policy.allow_http?`. MEDIATED.
- `host/policy.ex` — 3 profiles: `minimal` (vfs,commands — NO net), `network` (+net,llm,browse),
  `posix` (+posix,parallel). `allow_http?` derives from caps.
- wasmex `WasiP2Options.allow_http` flips `wasmtime_wasi_http::add_only_http_to_linker_sync` AND
  `wasi_ctx_builder.inherit_network()` + `allow_ip_name_lookup`.
- `host/browse.ex` — the web-browse path.

THE SECURITY HOLE (the core problem to solve):
- `inherit_network()` = the guest gets the HOST'S ENTIRE network stack (wasi-http + raw sockets + DNS),
  gated only by a BINARY net-or-no-net cap. A `net`-profile guest can reach 169.254.169.254 (cloud
  metadata/IAM creds), localhost:4000 (control plane), and RFC1918 internal ranges. No per-destination
  scope, no SSRF filter, no rate limit, no audit, no revocation. THIS is "the security cadence."

THE STANDARD-TOOL GAP:
- The 32 catalog tools are pure standalone wasm32-wasi, compiled with NO net imports. A standard C tool
  (curl, postgres client) uses raw BSD sockets, not our `host_http_get`. So today's broker only helps
  guests we hand-wrote. Need the STANDARD seam: back wasi-http (outbound HTTP) AND wasi-sockets (raw TCP)
  with a MEDIATED BEAM path, so unmodified WASI-standard tools transparently get safe brokered net.

## WORK QUEUE  (current keystone: SECURE host-brokered networking)

### PHASE 1 — Mediated egress seam (replace the inherit_network() hole)
- [ ] 1a. Stop using raw `inherit_network()` for guests. Route egress through a MEDIATED path the host
      fully controls: either (i) a wasmtime per-connection allow-list callback (socket_addr_check) so
      every connect() is checked, or (ii) force all HTTP through host_http_get-style brokering + a
      wasi-http handler the host implements (not inherit). Decide + implement. Keep `minimal` = no net.
- [ ] 1b. wasi-http OUTBOUND: a tiny guest using the standard `wasi:http/outgoing-handler` fetches a URL
      THROUGH the mediated broker (host does the I/O, Policy-checked). Prove it.
- [ ] 1c. wasi-sockets (raw TCP): confirm wasmex/wasmtime support; if present, back it with the mediated
      path; if absent, a custom host_tcp_connect/send/recv import + a tiny shim. Prove a raw-TCP guest.

### PHASE 2 — THE SECURITY CADENCE  (the deliverable that makes this shippable)
- [ ] 2a. SCOPED grants: Policy `net` becomes an ALLOW-LIST of {host, port} (or URL patterns), per
      instance — not all-or-nothing. Add a `net_allow` field; default deny.
- [ ] 2b. SSRF DEFENSE: before any connect, resolve the target and DENY loopback (127/8, ::1),
      link-local (169.254/16 incl. metadata 169.254.169.254, fe80::/10), RFC1918 (10/8,172.16/12,
      192.168/16), CGNAT (100.64/10), the host's own control-plane ports. Re-check AFTER DNS resolution
      (DNS-rebinding defense): resolve once, pin the IP, connect to that IP.
- [ ] 2c. RATE/QUOTA: per-instance caps — max requests, max bytes in/out, max concurrent conns, wall-clock.
- [ ] 2d. AUDIT: log every brokered net op {instance, profile, dest, bytes, verdict, latency}.
- [ ] 2e. REVOCATION: a running instance's net grant can be revoked mid-flight (in-flight conns dropped).
- [ ] 2f. ADVERSARIAL RED-TEAM (must ALL be blocked + tested): a hostile guest tries to reach metadata IP,
      localhost, RFC1918, the control plane; bypass the allow-list via IP-literals, IPv6, encoded/punycode
      hosts, redirect-to-internal (3xx Location), DNS-rebinding, decimal/octal/hex IP encodings, userinfo@
      tricks, open-redirect chaining; exfiltrate via DNS; DoS via huge bodies / many conns / slowloris.
      Each → a test that asserts BLOCKED. This is the gate: networking is NOT "done" until red-team passes.

### PHASE 3 — Inbound (server) flip
- [ ] 3a. Host-as-listener (Phoenix/cowboy) → per-request invoke a guest `wasi:http/incoming-handler`
      (or custom dispatch). Prove a guest "web app" serves a request, sandboxed, Policy-gated.
- [ ] 3b. Security: request data is the only input; same SSRF/quota cadence applies to any egress it makes.

### PHASE 4 — Reclaim the 323
- [ ] Re-run the feasibility pass WITH brokering: which network/server items now work? Wire keystones:
      a real HTTP client (curl-class), a DB client (not server), a package-manager fetch, an API tool.
      Update the original resolved.json: flip the now-reachable ones live with the brokered-net recipe.

## NEXT STONES (plan ahead — pull these once networking is proven secure)

- **Stone 2 — Exec→CommandRegistry dispatch (fork-exec brokering):** a guest's exec(cmd) is intercepted
  and dispatched to the in-sandbox CommandRegistry (32+ wasm commands). Unlocks Make/Ninja/shells/build-
  orchestrators FOR the subset of commands we have as wasm. Same Policy/audit cadence. Adversarial:
  command injection, arg-smuggling, reaching commands not granted.
- **Stone 3 — Brokered durable storage:** beyond the ephemeral VFS — a Policy-scoped, per-instance durable
  KV/blob store (host-backed), so stateful apps + "embedded DB" patterns persist. Quota'd, isolated.
- **Stone 4 — Threading fallback:** the "needs threads for SPEED not correctness" tools (set n_threads=1)
  + a host_parallel_map (fan out to fresh BEAM-managed instances) for embarrassingly-parallel work. The
  genuinely-shared-memory work-stealing case stays out (conceded).
- **Stone 5 — App-host platform:** productionize host-listener→guest-handler so the sandbox is a real
  deploy target (a wasm web app, request-scoped, autoscaled across BEAM processes). The "calculator → 
  platform" jump.

Conceded permanently OUT (do not chase): GPU compute, shared-memory work-stealing threads, native-binary-
emitting compilers-to-run-native (their wasm-targeting versions already answer the real need).

## STATE  (append newest at the bottom each turn)

- 2026-06-12: Campaign opened. Ground truth confirmed: host HTTP brokering EXISTS (host_http_get mediated;
  inherit_network unmediated = the SSRF hole). Security cadence is the core gap. Plan written. Loop armed.
  NEXT: Phase 1a — decide mediated-egress mechanism (socket_addr_check allow-list vs host-implemented
  wasi-http) + read the wasmex/Rust store.rs net wiring to find the exact intercept point.
- 2026-06-12 (iter 1): **EXACT PATCH POINT FOUND.** vendor/wasmex/native/wasmex/src/store.rs:260-263:
  `if options.allow_http { wasi_ctx_builder.inherit_network().allow_ip_name_lookup(true); }` — this is the
  SSRF hole (full host stack). wasmex is VENDORED+PATCHED already (vendor/wasmex/...), wasmtime 39.0.1 →
  `WasiCtxBuilder::socket_addr_check(closure)` IS available. FIX (Phase 1a+2a+2b in one patch):
  keep inherit_network() (provides the socket pool) but ADD `.socket_addr_check(|addr,_use| async move {
  allowed })` where `allowed` = NOT(addr.ip().is_loopback() || is_private() || is_link_local() ||
  is_unspecified() || is_metadata(169.254.169.254) || is_cgnat(100.64/10) || control_plane_port) AND
  (allow_list empty ? allow_external : addr in allow_list). Thread a `net_allow: Vec<String>` +
  `net_deny_internal: bool` through WasiP2Options (store.rs options struct ~line 50) ← Instance.ex (~line
  65) ← Policy (new per-profile/per-instance net scope). Rust std::net::IpAddr gives is_loopback/is_private/
  is_link_local/is_unspecified directly; 169.254.169.254 is caught by is_link_local. DNS-rebinding: socket_
  addr_check sees the RESOLVED SocketAddr (post-DNS), so checking the IP there closes rebinding automatically
  — that's why this hook is the right one (it fires at connect-time on the real IP, not the hostname).
  NEXT (iter 2): write the store.rs socket_addr_check patch + the SSRF filter fn + thread net_allow through
  WasiP2Options/Instance/Policy; cargo-rebuild the NIF; mix compile. Then iter 3: the adversarial red-team
  test (guest tries metadata/localhost/RFC1918 → assert blocked; allowed host → assert reachable).
- 2026-06-12 (iter 2): **RAW-SOCKET SSRF FILTER LANDED + UNIT-VALIDATED (green).** store.rs: added
  `socket_addr_check` on the net builder + `wb_ip_allowed()` SSRF filter (denies loopback/RFC1918/link-
  local[incl metadata 169.254.169.254]/CGNAT-100.64/ULA-fc00/link-local-fe80/multicast/broadcast/
  unspecified + IPv4-mapped-IPv6 normalization; allows public). 3 cargo tests GREEN over 34 adversarial
  address forms (incl ::ffff:127.0.0.1 bypass). NIF compiles (mix compile exit 0). socket_addr_check fires
  at connect-time on the RESOLVED addr → closes DNS-rebinding FOR THE RAW-SOCKET PATH.
  CLOSED: raw wasi-sockets egress SSRF.
  STILL OPEN (networking is NOT secure yet — do not claim done):
    (a) **wasi-http BYPASS** — wasmtime-wasi-http connects via tokio TcpStream::connect directly
        (types.rs:377), NOT through socket_addr_check. A wasi-http guest could still reach internal IPs.
        NEXT = override `WasiHttpView::send_request` (store.rs:113 impl) to wb_ip_allowed-check every
        resolved IP of the request authority before default_send_request; resolve-pin to close rebinding
        (needs a `hyper` dep at wasmtime-wasi-http's version + care w/ TLS SNI).
    (b) e2e integration proof — a REAL guest's connect actually blocked (unit test proves the fn; the
        wiring-to-a-live-guest is unproven). Need a wasi-sockets/wasi-http test guest.
    (c) scoped per-instance allow-list (today = deny-internal/allow-all-public; not yet {host,port} scoped).
    (d) quotas, audit log, mid-flight revocation.
  NEXT (iter 3): the wasi-http send_request override (the bigger half of the SSRF close).
- 2026-06-12 (iter 3): **wasi-http SSRF override LANDED (compiles + NIF loads/runs, green).** Added
  `WasiHttpView::send_request` override on ComponentStoreData (store.rs:217) + `wb_host_allowed()` (resolves
  the request authority, denies if ANY resolved IP fails wb_ip_allowed; denies on resolve-fail/empty).
  Added `hyper = "1"` dep (matches wasmtime-wasi-http 39's hyper 1.8). Denial via HttpError::trap(io::Error
  PermissionDenied). cargo build green, mix compile exit 0, NIF still loads+runs wasm (python 6*7=42 — no
  regression). 3 SSRF unit tests still green.
  NOW CLOSED: BOTH egress paths (raw wasi-sockets via socket_addr_check [pinned on resolved SocketAddr];
  wasi-http via send_request resolve-check) deny internal/sensitive destinations. Redirects are safe BY
  DESIGN — wasi-http returns 3xx to the guest; the guest's follow-up is a NEW request that re-enters
  send_request → re-checked. Encoded/decimal/hex/punycode hosts resolve to the same IP → caught.
  STILL OPEN (NOT declaring networking secure until these are done + e2e-proven):
    (1) **e2e INTEGRATION PROOF** — a REAL guest using wasi-http/wasi-sockets to hit 169.254.169.254 /
        127.0.0.1 must be demonstrably BLOCKED at runtime (so far: unit-tested filter + compile + NIF-load;
        the live-guest-blocked path is NOT yet demonstrated). THIS IS THE NEXT PRIORITY — rigor demands it.
    (2) active-DNS-rebinding window for wasi-http HOSTNAMES (raw-socket path is pinned; wasi-http resolve-
        check has a check→connect re-resolve gap; fix = pin resolved IP into a custom connector w/ SNI=host).
    (3) scoped per-instance {host,port} allow-list (today = deny-internal/allow-all-public).
    (4) rate/byte/conn quotas, audit log, mid-flight revocation.
  NEXT (iter 4): build a wasi-http (or wasi-sockets) TEST GUEST + prove at runtime it CANNOT reach metadata/
  localhost/RFC1918 (asserts the override actually fires), and CAN reach an allowed public host.

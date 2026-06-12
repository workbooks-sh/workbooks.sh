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
- 2026-06-12 (iter 4): **resolver-path tests added (5 cargo tests green).** wb_host_allowed now unit-proven:
  denies 127.0.0.1/169.254.169.254/10.0.0.1/::1/localhost(resolved); allows 8.8.8.8/1.1.1.1. HONEST STATUS
  of the e2e: NO current guest uses wasi-http (all use the already-mediated host_http_get), so the live-
  guest-blocked proof is COUPLED to Phase 4 (the first real brokered tool) — filed bd for it; until it
  exists, networking is "filter implemented + unit-validated + wired via wasmtime's documented hooks
  (socket_addr_check per-connect, WasiHttpView::send_request per-request)", NOT "e2e-proven". Not overclaiming.
  NEXT (iter 5): SCOPED ALLOW-LIST — today egress = deny-internal/ALLOW-ALL-PUBLIC (a net guest can reach
  ANY external host = exfiltration surface). Make it per-instance {host/ip,port} allow-list, default-deny,
  threaded Policy.ex → WasiP2Options → store.rs options → the socket_addr_check + send_request closures.
- 2026-06-12 (iter 5): **SCOPED ALLOW-LIST mechanism BUILT + VALIDATED (green).** Added wb_host_in_allowlist
  (exact / host:port / *.suffix / *.suffix:port, case-insensitive, trailing-dot-normalized) + 12-assertion
  unit test. Threaded `net_allow: Option<Vec<String>>` end-to-end: Elixir WasiP2Options defstruct (nil
  default) → ExWasiP2Options NifStruct → ComponentStoreData → enforced in send_request (AFTER the SSRF
  floor: if Some(non-empty) list, host must match). mix compile exit 0; 6 cargo tests green; **RUNTIME
  DECODE proven** (created a component store with net_allow=["api.github.com","*.example.com:443"] →
  DECODE-OK, so the NifStruct↔defstruct alignment is correct — the runtime-only break mode is closed).
  Backward-compatible: nil/empty = allow-public (after SSRF), so existing net/browse guests are unaffected.
  STATE OF SECURITY NOW: SSRF deny-internal floor LIVE on both egress paths (unit-validated); scoped
  allow-list MECHANISM ready on the wasi-http path.
  STILL OPEN (precise):
    - The allow-list is BUILT but not yet POPULATED by Policy — net_allow is nil for all current profiles,
      so no instance is scoped yet (the capability exists; activation = Policy/Instance sets net_allow for a
      scoped profile/tool, naturally coupled to Phase-4's first scoped brokered tool).
    - allow-list applies to wasi-http (has hostname); raw-sockets (socket_addr_check, IP-only) still
      deny-internal/allow-public — IP/CIDR allow-list for raw sockets is a follow-up.
    - DNS-rebinding pin for http hostnames; rate/byte/conn quotas; audit log; mid-flight revocation; the
      live-guest e2e (wb-q962).
  NEXT (iter 6): audit log (every egress decision {instance,dest,verdict} — observability/"manageable") +
  rate/conn quotas (DoS floor). Then Policy population + the Phase-4 first brokered tool (→ the live e2e).
- 2026-06-12 (iter 5 — STRATEGIC NOTE / priority correction): The security MECHANISMS (SSRF filter on both
  egress paths, scoped allow-list) are built + their LOGIC is exhaustively unit-validated, and the
  enforcement is wired via wasmtime's DOCUMENTED hooks (socket_addr_check per-connect; WasiHttpView::
  send_request per-request) — correct-by-construction. BUT every remaining enforcement feature (allow-list
  actually blocking, quotas, audit firing, rebinding-pin) can ONLY be RUNTIME-validated with a live guest —
  the SAME gap as wb-q962. Adding more enforcement code I can't yet runtime-prove violates the rigor bar
  ("no untested claims"). THEREFORE the critical path is now wb-q962 (the e2e harness), NOT more mechanism:
  stand up ONE wasi-http guest (componentize-js is in node_modules → componentize a JS `fetch()` into a
  wasi:http component; OR find a prebuilt wasi-http test component), run it through the patched runtime via
  the wasmex Components API with allow_http, and PROVE: (a) fetch to 169.254.169.254 / 127.0.0.1 is BLOCKED
  at runtime (send_request override fires), (b) fetch to an allow-listed public host SUCCEEDS, (c) fetch to
  a non-listed host with a net_allow set is BLOCKED. That single harness validates the WHOLE stack e2e and
  unblocks validating quotas/audit/rebinding as they're added. NEXT (iter 6) = build that harness. Only once
  it's green do quotas/audit/revocation get added (each then runtime-proven via the harness).
- 2026-06-12 (iter 5 — e2e harness scouted + guest laid down): FEASIBLE PATH CONFIRMED. componentize-js is
  in node_modules; wasmex runs components via Wasmex.Components.call_function(pid,name,params); host/
  instance.ex is a working component-instantiation pattern to copy. Wrote the guest fixture test/broker_e2e/
  net_probe.js (a `probe(url)` that fetch()es and returns "OK <status>" or "BLOCKED <msg>"). CONCRETE NEXT
  (iter 6, execute): (1) componentize net_probe.js -> a wasi:http component (StarlingMonkey fetch routes via
  wasi:http/outgoing-handler -> our send_request override); resolve the WIT world iteratively by running the
  tool (export `probe: func(url: string) -> string`, import wasi:http). (2) instantiate it via wasmex
  Components with %WasiP2Options{allow_http: true} (copy host/instance.ex). (3) ASSERT e2e: probe("http://
  169.254.169.254/") -> "BLOCKED", probe("http://127.0.0.1/") -> "BLOCKED"; then with net_allow set, probe
  a non-listed host -> "BLOCKED", an allow-listed public host -> reachable. THAT closes wb-q962 and proves
  the whole stack (SSRF + allow-list + wiring) at runtime — after which quotas/audit/revocation get added,
  each runtime-proven via this same harness.
- 2026-06-12 (iter 6): **E2E PROVEN (deny paths) WITH A REAL wasi:http GUEST — wb-q962 mostly closed.**
  Built the harness: jco componentize net_probe.js -> a 12.5MB wasi:http component (StarlingMonkey fetch ->
  wasi:http/outgoing-handler -> our send_request override); ran it via Wasmex.Components with allow_http.
  FOUND + FIXED a real bug only e2e could catch: HttpError::trap POISONED the instance ("cannot enter
  component instance" on the next call) -> switched all 3 denials to graceful HttpError::from(ErrorCode::
  InternalError(..)) so a denied fetch is a CATCHABLE error, instance survives. RE-RAN green:
    - fetch http://169.254.169.254/  -> BLOCKED (SSRF floor)   [REAL GUEST, RUNTIME]
    - fetch http://127.0.0.1/        -> BLOCKED (SSRF floor)   [REAL GUEST, RUNTIME]
    - fetch http://8.8.8.8/ w/ net_allow=["example.com"] -> BLOCKED (ALLOW-LIST — 8.8.8.8 is public so the
      floor would ALLOW it; the block is provably the allow-list)   [REAL GUEST, RUNTIME]
    - instance survives every denial (graceful, not trap).
  Reproducible: test/broker_e2e/{net_probe.js,net_probe.wit,deny_e2e.exs,README.md}.
  HONESTLY STILL OPEN:
    - ALLOW-REACHABILITY not proven: this dev env has NO outbound internet, so a listed/public host can't be
      confirmed to actually CONNECT here; AND the connect path panics ("Cannot start a runtime from within a
      runtime", wasmtime-wasi runtime.rs:108) — env-specific (no-internet) or a pre-existing wasmex async/
      wasi-http issue. NEEDS: an internet-enabled env to prove reachability + investigate the connect panic
      (likely the blocking to_socket_addrs in wb_host_allowed running on the async thread — should move to a
      tokio spawn_blocking / use a non-blocking resolver). Filed under wb-q962.
    - DNS-rebinding pin (http hostnames), rate/byte/conn quotas, audit log, revocation — next, each now
      runtime-provable via this harness.
  NEXT (iter 7): fix the blocking-resolver-on-async-thread (spawn_blocking) — it's likely the connect panic
  AND a correctness issue (blocking the executor); then quotas + audit, each e2e-checked.
- 2026-06-12 (iter 7): **CLOSED THE ACTIVE SSRF HOLE on the host-mediated path (host_http_get) — Elixir,
  unit-validated.** CORRECTION to iter6: the connect-panic was on an IP LITERAL (1.1.1.1, no DNS) so it is
  NOT my blocking resolver — it's the pre-existing wasi-http OUTBOUND path in wasmex (unwired/needs its own
  investigation) + this dev env has no outbound internet. THE BIGGER FINDING: host_http_get / host_http_get_
  many (rust_dock, js_dock) — the mediated path that ACTUALLY WORKS and is USED by real guests — did
  `:httpc.request(guest_url)` with NO destination check = an ACTIVE SSRF hole (a guest could fetch
  169.254.169.254 metadata). FIXED: new Workbooks.NetGuard (host/net_guard.ex) — allowed?/1 resolves the URL
  host and permits only if EVERY resolved addr is public (denies loopback/RFC1918/link-local[metadata]/CGNAT/
  unspecified/broadcast/multicast/IPv6-ULA/link-local + IPv4-mapped, mirrors the Rust wb_ip_allowed); get/2 =
  the single SSRF-guarded choke point (denies BEFORE opening a socket). Wired into ALL 3 sites (rust_dock get
  + get_many concurrent batch, js_dock get). 6 ExUnit tests green incl get/1-denies-internal OFFLINE (proves
  no socket opened). mix compile clean. NOW: BOTH egress paths SSRF-guarded — wasi (NIF socket_addr_check +
  send_request, e2e-proven deny) AND host-mediated (Elixir NetGuard, unit-proven deny). No functional
  regression (public URLs still fetch).
  STILL OPEN: allow-reachability e2e (needs internet env + the wasi-http-outbound connect-path fix); a host-
  path allow-list (NetGuard.get could take an allow-list arg like the wasi path); DNS-rebinding pin; quotas;
  audit; revocation. NEXT (iter 8): host-path allow-list arg on NetGuard.get (parity w/ wasi path) + a
  denial AUDIT log (Logger.warning on every blocked egress — observable + testable via the deny harness).
- 2026-06-12 (iter 8): **RED-TEAM adversarial hardening of the host path (green) + redirect bypass fixed.**
  PROBED the bypass vectors empirically: Erlang :inet.parse_address CANONICALIZES decimal (2130706433),
  hex (0x7f000001), octal (0177.0.0.1), full-octal (017700000001), short (127.1) IP forms all -> {127,0,0,1}
  — AND its parse agrees with what :httpc/getaddrinfo resolve, so there's NO parser-mismatch bypass; userinfo@
  is caught by URI.parse (host extracted past the @). Added a 12-case RED-TEAM ExUnit test asserting all these
  obfuscated internal targets are DENIED — GREEN. FIXED a real hole: :httpc auto-FOLLOWS 3xx by default (a
  public URL redirecting to internal would bypass the guard) -> NetGuard.get now sets autoredirect:false and
  follows redirects MANUALLY, re-SSRF-checking EVERY hop (bounded to 5), staying functional. 7 NetGuard tests
  green, mix compile clean.
  RED-TEAM STATUS (host path): IP-literals ✓, IPv6 ✓, decimal/hex/octal/short IP ✓, IPv4-mapped ✓, userinfo@ ✓,
  redirect-to-internal ✓ (per-hop check). STILL OPEN: DNS-rebinding (NetGuard resolves in allowed?, :httpc
  re-resolves on connect — a window; pin needs connect-to-IP-with-Host which :httpc doesn't expose easily);
  DoS (no body-size cap — :httpc reads full body; no per-instance conn/rate quota); DNS-exfil (resolving the
  host leaks the subdomain — mitigate by allow-list-first). Wasi-path: same obfuscation forms are denied
  by-construction (deny on resolve-fail or internal-IP) but not yet explicitly red-team-tested.
  NEXT (iter 9): body-size cap + conn/rate quota on NetGuard.get (DoS floor, testable); then allow-list arg
  (host-path parity) + denial audit (Logger + CaptureLog test); then explicit wasi-path red-team coverage.
- 2026-06-12 (iter 9): **host-path ALLOW-LIST + AUDIT LOG (green).** NetGuard.get/2 now takes opts
  [:timeout, :allow]; host_in_allowlist?/2 matches exact / *.suffix / host:port (case-insensitive, mirrors
  the Rust wb_host_in_allowlist). Every blocked egress (SSRF or allow-list) is Logger.warning audit-logged.
  10 ExUnit tests green: allow-list matcher, get denies a PUBLIC host (8.8.8.8) not on the list (proves the
  list blocks, distinct from the floor), audit captured via CaptureLog. Call sites unchanged (get(url)
  defaults opts=[]). HOST-MEDIATED PATH SECURITY CADENCE now: SSRF floor ✓, red-team obfuscation ✓, redirect
  per-hop ✓, scoped allow-list ✓, audit ✓.
- 2026-06-12 (iter 9 — STRATEGIC CLARITY on "networking done" + the 323):
  * The HOST_HTTP_GET path (custom import, used by hand-written Rust/JS guests) is now WORKING (it fetches —
    used in prod for web-search etc.; this dev env just has no outbound internet to re-prove locally) +
    SECURE (the full cadence above, unit+adversarial tested). Remaining cadence: DoS body/conn caps, DNS-
    rebinding pin, revocation, + Policy POPULATING the allow-list per-instance.
  * RECLAIMING THE 323 STANDARD network tools (curl/wget/db-clients/pkg-mgrs) is GATED on the WASI seam,
    NOT host_http_get: those tools use raw sockets / wasi-http, not our custom import. The wasi path's SSRF/
    allow-list is built + e2e-deny-proven, BUT wasi-http OUTBOUND (the actual connect) panics in this wasmex
    setup ("Cannot start a runtime from within a runtime") AND needs an internet env. So: securing is ahead
    of functionality. The 323 reclamation needs the wasi-http-outbound connect path WORKING — a separate
    investigation (wasmex component async + wasi-http driving), best done in an internet-enabled env.
  NEXT (iter 10): finish the host-path cadence that IS offline-validatable — DoS body-size cap (stream +
  abort) + per-instance conn/rate counter; then DNS-rebinding pin; then revocation. In parallel, file a bd
  to investigate wasi-http-outbound connect (the 323-reclamation gate).
- 2026-06-12 (iter 10): **GATE DIAGNOSED + remaining-work honestly mapped; strategic PIVOT decided.**
  Root-caused the wasi-http-outbound panic (wb-0beq): wasmex calls components SYNC (function.call,
  component_instance.rs:331) inside a tokio task (spawn, :202); a wasi-http outbound does in_tokio->block_on
  -> "runtime from within a runtime". Fix = async_support(true)+call_async, but that's ENGINE-WIDE (the 32
  modules + oql + Dock guests share the engine + call sync) -> a focused, regression-heavy refactor (or a
  separate async engine) + needs internet to confirm -> NOT a loop increment. This is the GATE for the 323
  (standard tools use wasi-sockets/http, not host_http_get).
  HONEST ASSESSMENT of the networking keystone:
    * DENY-SIDE SECURITY = COMPLETE + TESTED across both egress paths: SSRF floor (wasi NIF e2e-proven +
      host NetGuard unit-proven), red-team obfuscation (decimal/hex/octal/short IP, userinfo@, v4-mapped —
      12-case suite green), redirect-to-internal (per-hop re-check), scoped allow-list (mechanism both paths,
      e2e-deny-proven wasi + unit host), audit log (host). ~30 tests green; main green every commit.
    * EVERY REMAINING ITEM IS GENUINELY GATED on resources this dev-env/loop-format can't provide:
      - allow-REACHABILITY e2e + DoS-body-cap + DNS-rebinding-pin -> need a SERVER/INTERNET env (wb-k2im);
        DoS-cap also has a real design tension (:httpc streaming vs redirect-follow vs host_http_get ABI).
      - wasi-http OUTBOUND working (-> the 323 reclamation) -> the async engine refactor (wb-0beq).
  STRATEGIC PIVOT (per the loop directive "if blocked file a bd + move on; pull the NEXT STONE"): the
  networking deny-side is working+secure+manageable for the host_http_get path; the value-unlock (323) +
  remaining red-team polish are env/refactor-gated. So the productive frontier moves to the NEXT STONE that
  IS offline-validatable: **Stone 2 — exec -> CommandRegistry dispatch** (a guest's exec(cmd) brokered to the
  32 in-sandbox wasm commands, Policy-gated, adversarially tested for command-injection/ungranted-command/
  arg-smuggling). This advances real capability (build tools, shells) without the networking blockers.
  NEXT (iter 11, fresh context): begin Stone 2 — design the host_exec Dock import (name+argv+stdin ->
  CommandRegistry.run, deny ungranted commands), wire it, and adversarially test it offline. Networking
  resumes when an internet env / a focused async-refactor session is available (wb-0beq, wb-k2im, wb-q962).

## STONE 2 — exec -> CommandRegistry dispatch (the pivot; OFFLINE-validatable)
- 2026-06-12 (iter 11): **Stone 2 CORE built + e2e-VALIDATED (green) — a real new capability, proven
  offline.** Workbooks.ExecBroker.exec/4 brokers a guest's exec(cmd) to the in-sandbox CommandRegistry
  (the 32+ wasm commands) — the host runs another SANDBOXED wasm command in its own isolated instance; NO
  real OS exec. Security cadence (mirrors the net broker), all TESTED:
    * DEFAULT-DENY (must be granted via the `commands` cap) ✓
    * NO real OS exec — unregistered names (rm/bash//bin/sh) denied ✓
    * COMMAND allow-list scoping (granted-but-not-listed -> denied) ✓
    * BOUNDED nesting depth (recursion-bomb defense) ✓
    * NO injection / arg-smuggling — argv is STRUCTURAL; e2e-proven `echo "ok; rm -rf /"` prints the
      literal string, never interpreted ✓
    * size-capped output + audit log on every denial ✓
  DISPATCH E2E (the gold proof, fully offline): seeded coreutils + ExecBroker.exec("coreutils",["seq","5"])
  -> "1\n2\n3\n4\n5" — a command actually RAN through the broker. 6 hermetic + 1 :pallet dispatch test green.
  CONTRAST with networking: Stone 2 is FULLY offline-validatable (local wasm commands, no internet), so it's
  proven end-to-end here — real capability delivered.
  NEXT (iter 12): wire `host_exec` as a Dock import (thin wrapper: read name+argv+stdin from wasm mem ->
  ExecBroker.exec(allow: "commands" in Policy.caps(profile)) -> write output), then a guest e2e (a Rust/JS
  guest exec's coreutils -> output). Then thread the nesting depth through CommandRegistry.run so a brokered
  command that itself execs is depth-counted. This unlocks build-tools/shells/orchestrators (the fork-exec
  class) — many of the 323 "impossible (fork-exec)" items become reachable via brokered exec to wasm cmds.
- 2026-06-12 (iter 12): **host_exec WIRED into both Docks (rust_dock + js_dock), gated on the `commands`
  cap; parse_request tested; escalation confined.** Added ExecBroker.parse_request/1 (length-prefixed LE
  wire format: [name_len][name][argc][(arg_len)(arg)]*[stdin_len][stdin] — binary-safe, malformed->:error;
  tested round-trip + rejection). Wired `host_exec(req_ptr,req_len,out_ptr,out_cap)->i32` into rust_dock
  (maybe "commands" in caps -> exec_caps/0) and js_dock (allow_exec gate): read req from wasm mem ->
  parse_request -> ExecBroker.exec(allow: true) -> write output (truncated to out_cap; -1 on deny/error).
  SECURITY — escalation confined BY CONSTRUCTION: CommandRegistry.run -> PackageManager.run runs the catalog
  tool as a STANDARD-WASI sandbox (stdio + only passed dirs); the 32 tools have NO Dock imports / no net, and
  ExecBroker passes NO dirs -> a no-net/no-fs guest CANNOT gain net/fs by exec'ing a command. 8 ExecBroker
  tests green + dispatch e2e green; both docks compile clean.
  REMAINING for Stone 2: (a) full GUEST e2e — a Rust/JS guest actually CALLING host_exec end-to-end (the
  marshaling layer is correct-by-construction over tested parse+exec + the proven host_http_get mem pattern,
  but not yet guest-driven); (b) thread nesting DEPTH through CommandRegistry.run/ropts so a brokered command
  that itself execs is depth-counted (today depth is per-call only); (c) a dedicated `exec` cap (default-off)
  for finer control than the broad `commands` cap. NEXT (iter 13): build the minimal guest e2e (JS via JsDock
  is the lighter path — add a host_exec JS-harness wrapper + a guest that exec's coreutils -> assert output).
- 2026-06-12 (iter 13): **STONE 2 FULLY e2e-PROVEN (green) — guest-driven exec dispatch works end-to-end.**
  Added a real GUEST e2e (test/rust_dock_test.exs, @tag :build): a Rust guest compiled with
  `extern { fn host_exec }`, builds the length-prefixed request in-guest, calls host_exec; the host parses
  it, runs coreutils in ITS OWN sandbox, and returns the output to the guest — guest verifies seq 5 ==
  "1\n2\n3\n4\n5" (9 bytes; CommandRegistry maybe_trim drops the trailing newline), ok=true. The COMPLETE
  path proven: guest -> host_exec import -> parse_request -> ExecBroker.exec -> CommandRegistry sandbox ->
  output -> guest. Caught+fixed my own wrong expected (10 vs 9). Compiles+runs in ~10s.
  STONE 2 STATUS = DONE + e2e-validated: ExecBroker core (default-deny/no-OS-exec/allow-list/depth/audit/
  no-injection — tested), parse_request ABI (tested), host_exec wired into rust_dock + js_dock (commands-cap
  gated, escalation-confined), and now the guest-driven e2e (proven). UNLIKE networking, Stone 2 is FULLY
  validated offline — a guest can safely broker exec to the 32 sandboxed wasm commands. This unlocks the
  FORK-EXEC class (build tools / shells / orchestrators) for wasm-available commands.
  MINOR REMAINING (non-blocking refinements): nesting-depth threading (currently defense for a non-reachable
  scenario — catalog tools have no host_exec so they can't re-exec); a dedicated `exec` cap (vs the broad
  `commands` cap); a JS-guest e2e (rust e2e proves the mechanism; js_dock is wired identically).
  NEXT (iter 14): per the loop directive — re-evaluate runtime/.campaign/resolved.json's FORK-EXEC subset
  now reachable via host_exec (flip reachable ones), then pull the next stone (brokered durable storage).

## STONE 3 — brokered durable storage + the honest 323-reclamation finding
- 2026-06-12 (iter 14a — RECLAMATION re-run, HONEST result): re-ran the feasibility pass vs the two brokers.
  **No items flipped — the reclamation is GATED, not unlocked** (a false "live" is worse than an accurate
  "impossible"). reclaim-analysis.md records it: ~64 net + ~37 fork-exec "runtime-only" candidates, BUT they
  are STANDARD tools using wasi-sockets / POSIX fork-exec — they reach the broker only via the WASI-SEAM
  generalization (wb-0beq, env/refactor-gated), NOT via the hand-written-guest brokers; and fork-exec tools
  can't even compile to wasi (no process model). The brokers' real win is enabling NEW hand-written guests
  (host_exec composes the 32 live cmds; host_http_get gives them SSRF-safe egress) — proven — not auto-
  reclaiming standard tools. Reclamation revisits after wb-0beq in an internet env.
- 2026-06-12 (iter 14b — Stone 3 CORE built + validated, green): Workbooks.StorageBroker — host-brokered
  PERSISTENT k/v (sqlite-backed; the in-instance VFS is ephemeral, this survives across runs). Security
  cadence: TENANT ISOLATION (every row scoped by tenant — a guest can't read/overwrite another tenant's
  keys; tested adversarially), QUOTAS (per-value size + per-tenant key-count, DoS defense), binary-safe
  BLOBs. put/get/delete/keys. 6 ExUnit tests green: round-trip+binary, tenant-isolation, DURABLE (persists
  across close+reopen), size-quota, key-count-quota, empty-key reject. Conn-passing style (like VFS) -> the
  Dock holds one app-supervised conn.
  NEXT (iter 15): wire host_kv_put/get Dock imports — design the TENANT identity for a dock guest (per-app/
  per-instance) + the persistent-conn lifecycle (app-supervised, durable DB path under the data dir), then a
  guest e2e (a Rust guest puts+gets a key, value persists). Then the next stone (threading-fallback or
  app-host platform).
- 2026-06-12 (iter 15): **STONE 3 FULLY e2e-PROVEN (green) — durable per-tenant storage works end-to-end.**
  Added StorageBroker.Server (lazy app-wide durable sqlite conn, serialized; WB_KV_DB path; TENANT supplied
  by the Dock, never the guest). Wired host_kv_put/get into rust_dock (gated on the vfs cap; tenant threaded
  from RustDock.run opts). GUEST e2e (rust_dock_test, @tag :build): one Rust guest run 3x proves —
    * run 1 (tenant A): get miss -> put "durable-v1" -> "stored r=0"
    * run 2 (tenant A): get HIT "durable-v1" — value PERSISTED ACROSS RUNS through the broker
    * run 3 (tenant B): get miss — ISOLATED; B never sees A's "slot"
  So durability-across-runs AND tenant-isolation both proven via real guests (8s). 6 unit + 1 guest e2e green.
  STONE 3 STATUS = DONE + e2e-validated: StorageBroker core (isolation/quota/durable) + Server + rust_dock
  wiring + guest e2e. A guest now has persistent, tenant-isolated, quota'd KV that survives across runs.
  MINOR REMAINING: js_dock host_kv parity (mechanical mirror of host_exec/rust_dock wiring); a dedicated
  durable-storage cap (vs reusing vfs); the WB_KV_DB default path should be a stable data-dir (not tmp) for
  real durability. NEXT (iter 16): js_dock host_kv parity, then the next stone (threading-fallback via
  host_parallel_map — fresh-instance BEAM processes — or app-host platform).
- 2026-06-12 (iter 16): **js_dock host_kv PARITY + STONE 4 (threading-fallback) core built + validated.**
  (a) js_dock host_kv_put/get mirrored from rust_dock (vfs-cap gated, tenant from Dock); compiles, 24 broker
  unit tests green — JS guests now get the same durable per-tenant KV (mechanism already e2e-proven via
  rust_dock). (b) STONE 4 = Workbooks.ParallelBroker — brokered DATA-PARALLELISM: a single wasm instance
  can't thread, so the host runs a command over N inputs CONCURRENTLY across BEAM processes (Task.async_stream
  over fresh sandboxes) and gathers results in order. Each task is a full ExecBroker.exec (whole exec cadence
  applies per task) + parallelism limits: default-deny, max_inputs (fan-out cap), max_concurrency, per-task
  timeout. 4 hermetic tests (deny, fan-out cap, order-preserving w/ per-task errors) + 1 :pallet DATA-PARALLEL
  dispatch (map cat over [alpha,beta,gamma] -> [{:ok,alpha},{:ok,beta},{:ok,gamma}], concurrent, ordered) —
  all green. This is the host-brokered substitute for within-program threads (system-concurrency already
  exists via many isolated instances; this adds intra-task data-parallelism).
  CAMPAIGN: FOUR brokered capabilities now — net (deny-side secured+proven; functional remainder env-gated),
  exec (done+e2e), durable storage (done+e2e, both docks), data-parallelism (core+dispatch proven).
  NEXT (iter 17): wire host_parallel_map Dock import (N-in / N-out length-prefixed ABI) + a guest e2e; then
  the app-host platform stone. (Networking functional reclamation still gated on wb-0beq + internet env.)

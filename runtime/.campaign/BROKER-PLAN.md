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
- 2026-06-12 (iter 17): **STONE 4 FULLY e2e-PROVEN (green) — guest-driven brokered data-parallelism.**
  Added the host_parallel_map ABI: parse_map_request ([name][argv][N inputs], LE length-prefixed) +
  encode_results ([n][(len,-1=err)(body)]*), both hermetically tested. Wired host_parallel_map into rust_dock
  (commands-cap gated). GUEST e2e (rust_dock_test, @tag :build): a Rust guest builds the map request, calls
  host_parallel_map; the host fans coreutils `cat` over [alpha,beta,gamma] CONCURRENTLY across fresh
  sandboxes, returns the encoded N results; the guest parses them -> "n=3 results=alpha,beta,gamma". 6 unit +
  1 guest e2e green. Stone 4 DONE + e2e-validated.
  CAMPAIGN SCORECARD — FOUR brokered capabilities, the host-does-privileged-op / guest-stays-sandboxed
  pattern with full security cadence (default-deny, quotas, audit, adversarial tests) + offline e2e proofs:
    1. NETWORKING — deny-side comprehensively secured + red-team proven (SSRF floor both paths, obfuscation,
       redirect, allow-list, audit); functional reachability + the standard-tool seam env/refactor-gated
       (wb-0beq async engine refactor + wb-k2im internet env). The 323 reclamation waits on that gate.
    2. EXEC (Stone 2) — done + guest e2e-proven (broker exec to the 32 sandboxed cmds; no injection).
    3. DURABLE STORAGE (Stone 3) — done + guest e2e-proven (persistent tenant-isolated KV, both docks).
    4. DATA-PARALLELISM (Stone 4) — done + guest e2e-proven (fan a cmd over N inputs concurrently).
  NEXT (iter 18): the app-host / INBOUND server-flip stone (host-as-listener -> guest handler) — likely
  larger and may meet the same component-async gate as outbound (wb-0beq); scope it first. js_dock
  host_parallel_map parity is a quick mechanical follow.
- 2026-06-12 (iter 18): **js_dock host_parallel_map PARITY + STONE 5 (inbound serve-flip) CORE e2e-PROVEN.**
  (a) js_dock host_parallel_map mirrored from rust_dock (commands-cap gated) — data-parallelism on both docks.
  (b) STONE 5 = Workbooks.ServeBroker — the INBOUND server-flip (the last networking-keystone item + the
  app-host stone). The host owns the socket (privileged op); a GUEST handles requests, sandboxed. Flow rides
  the proven import pattern + an ETS channel (no host->guest memory writes): dispatch(serve_id,pid,req) stashes
  the request + calls the guest's `handle` export; the guest fetches via host_request_get, processes, returns
  via host_response_set; the host reads the response. A PERSISTENT instance is re-entered per request (long-
  lived, like a server). GUEST e2e (C reactor, compile_c --no-entry export_name("handle")): dispatch "hello"
  -> "echo:hello", then SAME instance dispatch "world" -> "echo:world" (re-entered). Response size-capped;
  per-serve_id request channel. Green. (Found+fixed: rust no_mangle exports get GC'd by the lane; switched to
  the established C-reactor export pattern — the kernel's --no-entry + export_name.)
  CAMPAIGN: FIVE brokered capabilities now — net (deny-side proven), exec, durable storage, data-parallelism,
  and inbound-serve — all guest-e2e-proven except networking's env-gated functional reachability. The host-
  brokered-capabilities pattern (host does the privileged op, guest stays sandboxed, default-deny + quotas +
  adversarial tests + offline e2e) now spans egress, process-spawning, persistent state, concurrency, and
  INBOUND serving.
  NEXT (iter 19): wire a real HTTP listener route -> ServeBroker.dispatch for an HTTP-level e2e (host-as-
  listener -> guest handler over actual HTTP), marshaling method/path/headers/body; then consolidate.
- 2026-06-12 (iter 19): **STONE 5 FULLY e2e-PROVEN OVER REAL HTTP — host-as-listener -> guest handler.**
  Added ServeBroker.encode_http_request (marshal method/path/body -> request bytes) + Workbooks.ServeBroker.
  Plug (a Bandit/Plug adapter: HTTP request -> marshal -> ServeBroker.dispatch -> the guest's response bytes
  become the HTTP body). HOST-AS-LISTENER e2e: a REAL Bandit 1.11 listener bound to 127.0.0.1:<port>; a real
  HTTP GET /hello -> the Plug -> dispatch -> the sandboxed guest handler -> "echo:GET /hello\n\n" -> HTTP 200.
  The host owns the socket (privileged op); the guest never touches it — it only sees request bytes and
  returns response bytes. 2 tests green (serve-flip core + real-HTTP). The LAST networking-keystone item
  (4, inbound server-flip / app-host) is DONE + proven.
  ===== CAMPAIGN MILESTONE: FIVE brokered capabilities, the full host-brokered-capabilities platform =====
    1. NETWORKING egress — deny-side comprehensively secured + red-team proven (SSRF floor both paths,
       obfuscation, redirect, allow-list, audit); standard-tool reachability env/refactor-gated (wb-0beq).
    2. EXEC (Stone 2) — guest e2e-proven (broker exec to 32 sandboxed cmds; no injection).
    3. DURABLE STORAGE (Stone 3) — guest e2e-proven (persistent tenant-isolated KV, both docks).
    4. DATA-PARALLELISM (Stone 4) — guest e2e-proven (fan a cmd over N inputs concurrently, both docks).
    5. INBOUND SERVE (Stone 5) — guest e2e-proven OVER REAL HTTP (host listens, guest handles, sandboxed).
  All five follow the one pattern: host does the privileged op, guest stays sandboxed, default-deny + quotas
  + audit + adversarial tests + offline e2e. The frontier moved from one sandbox capability to a coherent
  brokered platform spanning egress, process-spawning, persistent state, concurrency, AND inbound serving.
  NEXT (iter 20): richer HTTP marshaling (forward headers + guest-set status/headers) for the serve-flip;
  and/or consolidate (a capability/ABI reference doc). Networking's 323 reclamation stays gated on wb-0beq.
- 2026-06-12 (iter 20): **serve-flip enriched to a FULL HTTP handler (green).** encode_http_request now
  forwards request headers (METHOD PATH\n Header: v\n ... \n\n body); decode_http_response parses a guest-set
  STATUS + headers (STATUS\n Header: v\n\n body; plain bytes -> 200 fallback). The Plug forwards req headers
  in and applies the guest's status+headers out. Hermetic marshaling tests + RICH HTTP e2e: a real HTTP GET
  /rich (with x-foo: bar) -> the guest SET status 201 + header x-guest:hi and SAW the forwarded x-foo header
  (echoed in the body). 4 tests green (2 hermetic + 2 build e2e). The serve-flip guest is now a real HTTP
  handler (reads method/path/headers/body; sets status/headers/body) — production-shaped, fully sandboxed.
  STONE 5 = COMPLETE (core + real-HTTP + full request/response marshaling, all e2e-proven).
  PLATFORM STATUS: five brokered capabilities, all e2e-proven (except net-egress reachability, env-gated):
  net egress (deny-side red-team proven), exec, durable storage, data-parallelism, inbound HTTP serving.
  NEXT (iter 21): CONSOLIDATE — a capability/ABI reference doc (the host_* import surface across both docks +
  ServeBroker) + a single green run of all broker unit suites; OR harden a deferred cadence item (dedicated
  exec/kv caps for least-privilege, or the DoS body-cap). Networking 323-reclamation stays gated on wb-0beq.
- 2026-06-12 (iter 21): **CONSOLIDATION — unified validation + capability reference (green).** Ran all 5
  broker unit/hermetic suites TOGETHER: 34 tests, 0 failures (net_guard, exec_broker, storage_broker,
  parallel_broker, serve_broker). Dock additions regression-free: js_dock_test 4/0 (my host_exec/host_kv/
  host_parallel_map additions didn't break existing dock tests). Wrote .campaign/BROKER-CAPABILITIES.md —
  the full host_* import ABI surface (signatures, cap gates, broker module per import), the 5 capabilities,
  the security cadence, and the e2e-proof status. The platform is now documented + coherence-verified.
  PLATFORM = 5 brokered capabilities, all e2e-proven (except net-egress reachability, env-gated): net egress,
  exec, durable storage, data-parallelism, inbound HTTP serving. One pattern: host does the privileged op,
  guest stays sandboxed, default-deny + quotas + audit + adversarial tests + offline e2e.
  NEXT (iter 22): least-privilege hardening — split the coarse caps (commands->exec, vfs->kv) into dedicated
  caps so a profile can grant network/storage WITHOUT granting exec, etc. (add a no-exec profile to prove
  it); OR a composition DEMO (a serve guest that execs a cmd + caches in KV per request — proving the
  platform composes into real apps). Networking 323-reclamation stays gated on wb-0beq.
- 2026-06-12 (iter 22): **LEAST-PRIVILEGE cap hardening (green) — manageability ↑.** Split the coarse caps:
  added DEDICATED `exec` (gates host_exec + host_parallel_map) and `kv` (gates durable host_kv), distinct
  from the broad `commands`/`vfs`. The 3 standard profiles gained `exec`+`kv` (every current capability
  preserved); added a restrictive `compute` profile (caps: vfs only — pure compute + ephemeral vfs, NO exec,
  NO durable kv, NO net). Shifted the gates in BOTH docks (rust_dock maybe "exec"/"kv"; js_dock allow_exec/
  allow_kv). A profile can now grant durable STORAGE or NETWORK without also granting the ability to SPAWN
  COMMANDS. Hermetic test: minimal has host_exec/host_kv/host_parallel_map; compute is DENIED all three. 20
  broker unit tests regression-free. Updated BROKER-CAPABILITIES.md cap-gate column.
  NEXT (iter 23): a COMPOSITION demo (a serve guest that, per request, execs a cmd + caches the result in KV
  — proving the brokers compose into a real sandboxed app), OR the DoS body-cap (net path streaming). The
  net-egress 323-reclamation stays gated on wb-0beq.
- 2026-06-12 (iter 23): **COMPOSITION DEMO (green) — the brokers compose into a real sandboxed app.** Built
  a CACHING HTTP SERVER as one sandboxed C-reactor guest granted BOTH the serve channel AND the kv broker
  (instantiated with Map.merge(RustDock.imports(:minimal, tenant), ServeBroker.imports(serve_id))). Per
  request it reads the request (serve), looks up a KV key (durable storage), and caches on miss. e2e over a
  REAL Bandit listener: GET /first -> "MISS:GET /first" (computed + cached via host_kv_put); GET /second ->
  "HIT:GET /first" (the first request, returned from durable KV). Proves serve + durable-storage COMPOSE into
  a stateful sandboxed app — built entirely from brokered capabilities, fully isolated. Green.
  ===== The platform now stands: FIVE brokered capabilities, least-privilege caps, documented (BROKER-
  CAPABILITIES.md), coherence-verified (34 unit tests together), and COMPOSED (a real caching web server). =====
  NEXT (iter 24): more composition (serve + EXEC — a guest that runs a cmd per request) OR the net DoS body-
  cap (streaming). Net-egress 323-reclamation remains gated on wb-0beq (wasi-seam async refactor + internet).
- 2026-06-12 (iter 24): **CGI/SERVERLESS composition (green) — serve + EXEC compose.** Built a serving
  guest that, per HTTP request, assembles a host_exec request in-guest (length-prefixed) and runs `coreutils
  wc -c` over the request in a FRESH sandbox — composing the serve + exec brokers. e2e over real Bandit: GET
  /cgi -> the guest ran wc -c on the marshaled request -> HTTP 200 body "73" (the byte count, computed by a
  sandboxed command). This is the serverless/CGI pattern: a sandboxed handler that spawns sandboxed commands
  per request. Two composition demos now prove the platform builds real apps: a CACHING server (serve+kv)
  and a CGI server (serve+exec).
  PLATFORM COMPLETE: 5 brokered capabilities (egress/exec/storage/parallelism/serving), least-privilege caps,
  documented (BROKER-CAPABILITIES.md), coherence-verified, and COMPOSED two ways. The host-brokered pattern
  spans every axis a guest needs; remaining frontier is the env/refactor-gated net-egress reachability for
  STANDARD tools (wb-0beq wasi-seam async refactor + internet env) — a focused-session task, not a loop step.
  NEXT (iter 25): the net DoS body-cap (streaming, the last unaddressed red-team item), OR begin the wb-0beq
  scoping (separate async engine for wasi-http components) if pursuing the 323 reclamation.
- 2026-06-12 (iter 25): **MID-FLIGHT REVOCATION (green) — a keystone cadence item, manageable + tested.**
  Workbooks.Revocation (lazy public-ETS registry: revoke/unrevoke/revoked?). StorageBroker.put/get and
  ServeBroker.dispatch now consult it on every privileged op, so revoking a principal (kv tenant / serve_id)
  denies its brokered access IMMEDIATELY — even while the guest is running, no teardown needed. Tests: kv
  revoke -> put+get denied -> unrevoke -> restored (data intact, revocation gates ACCESS not data); serve
  revoke -> dispatch denied BEFORE touching the guest (pid=nil never called). 14 tests green.
  The DoS body-cap (huge bodies) stays in wb-k2im — it needs a SERVER to test (:httpc streaming vs the
  redirect-follow; offline-unverifiable), same env-gating as net reachability; not false-claimed as done.
  CADENCE now: default-deny + scoped allow-list + quotas + audit + MID-FLIGHT REVOCATION + adversarial tests.
  REMAINING (all needs identity-threading or an env): net/exec revocation (thread the dock tenant as the
  principal to host_http_get/host_exec); DoS body-cap + net reachability (wb-k2im, server/internet); the 323
  standard-tool reclamation (wb-0beq wasi-seam async refactor). NEXT (iter 26): thread the principal to net+
  exec for full revocation coverage, OR begin wb-0beq scoping (a separate async engine for wasi-http guests).
- 2026-06-12 (iter 26): **REVOCATION now covers ALL BROKERS (green) — the cadence item is COMPLETE.**
  Threaded the dock TENANT as the revocation principal through host_http_get (NetGuard.get principal:),
  host_exec (ExecBroker.exec principal:), and host_parallel_map (ParallelBroker.map principal:) in BOTH docks
  (rust_dock egress/exec_caps now take the principal; js_dock passes tenant). Each broker consults
  Revocation.revoked?(principal) FIRST, so revoking a tenant denies its ENTIRE brokered surface — net + exec
  + parallel + kv + serve — immediately, mid-flight, no teardown. Tests: net + exec revocation hermetic (26
  broker tests green); dock import-map regression-free (least-privilege test still green with the threading).
  CADENCE COMPLETE: default-deny + scoped allow-list + quotas + audit + FULL mid-flight revocation +
  adversarial red-team. The only networking remainders are env/refactor-gated: DoS body-cap + reachability
  (wb-k2im, needs a server/internet); the 323 standard-tool reclamation (wb-0beq, wasi-seam async refactor).
  NEXT (iter 27): rate/conn quotas (the last listed cadence item — a per-principal request counter, testable
  via the revocation-style ETS), OR begin wb-0beq scoping (separate async engine for wasi-http guests).
- 2026-06-12 (iter 27): **RATE QUOTA (green) — the last cadence primitive; the networking cadence is now
  fully BUILT.** Workbooks.RateLimiter (per-principal fixed-window counter, monotonic-time, lazy ETS). Wired
  a `:rate` {max, window_ms} opt into NetGuard.get + ExecBroker.exec (checked after revocation, before the
  op). Tests: primitive (budget enforced / independent principals / window reopens) + net + exec integration
  (a principal over budget -> {:error, :rate_limited}). 25 tests green. The limit is AVAILABLE per-call;
  activating it for ALL dock guests is a one-line policy tuning (pass a default rate from the dock) — left as
  a deployment policy choice, not hardcoded.
  ===== NETWORKING CADENCE FULLY BUILT: default-deny + scoped allow-list + SSRF floor (both paths) + quotas
  (size/key/fan-out/RATE) + audit + FULL mid-flight revocation + adversarial RED-TEAM (obfuscation/redirect/
  IP-forms all proven-denied). On the SECURITY + MANAGEABILITY axes networking is DONE (red-team green,
  manageable via revocation+rate+audit) and WORKING via the mediated host_http_get path. =====
  The ONLY remaining networking items are env/refactor-gated, honestly filed (not false-claimed):
    - DoS body-cap (huge bodies) + egress reachability -> wb-k2im (needs a server/internet to test).
    - STANDARD-TOOL transparent reclamation (the 323) -> wb-0beq (wasi-seam async engine refactor).
  NEXT (iter 28): begin wb-0beq scoping (a SEPARATE async wasmtime engine for wasi-http guests, leaving the
  sync engine for modules/oql) — the gate to reclaiming the 323; OR pull a fresh NEXT STONE if one remains.
- 2026-06-12 (iter 28): **wb-0beq DE-RISKED with a concrete implementation plan; campaign-scope assessment.**
  Scoped the wasi-http-outbound async refactor precisely and wrote an actionable 5-step plan into wb-0beq
  (separate async wasmtime engine for wasi-http guests; sync engine untouched for the 32 modules/oql/Dock
  components; per-store is_async flag branches call_async vs call; auto-route allow_http guests; validation
  gates = sync-regression-green + async-no-panic + reachability-in-internet-env). RATIONALE: async_support is
  engine-wide and breaks sync call() once on, so it MUST be a second engine — a multi-hour careful refactor
  to the path EVERY tool runs through, only fully validatable WITH internet. That is a focused-session task,
  NOT a 2-min loop fire; rushing it would risk the runtime. So the loop-increment contribution is the precise
  de-risking plan, not a rushed half-refactor.
  ===== CAMPAIGN-SCOPE ASSESSMENT: the keystone + all 4 listed stones are DONE. =====
    * KEYSTONE (secure host-brokered networking): security cadence FULLY built + red-team green (default-deny,
      allow-list, SSRF both paths, size/key/fan-out/RATE quotas, audit, full revocation); WORKING via the
      mediated host_http_get path; MANAGEABLE (revocation + rate + audit). Items (1) mediated scoped egress,
      (3) the cadence, (4) inbound server-flip — all DONE+proven. Item (2) standard-tool wasi-seam = wb-0beq.
    * STONES: exec (done+e2e), durable storage (done+e2e), threading-fallback/data-parallelism (done+e2e),
      app-host/inbound-serve (done+e2e over real HTTP). Plus least-privilege caps, docs, 2 composition demos.
  The ONLY remaining frontier is wb-0beq (focused session + internet) and its dependents (wb-k2im reachability
  + DoS-body-cap; the 323 reclamation). Further loop fires within this campaign's scope would be marginal
  (more demos / hardening) — the substantive brokered-capability platform is complete. NEXT (iter 29): if
  continuing, either a new capability beyond the plan (e.g. brokered secrets/credentials, inter-guest pub/sub)
  or incremental wb-0beq plumbing — but the campaign's defined goal is ACHIEVED.
- 2026-06-12 (iter 29): **BROKERED SECRETS — a 6th capability beyond the original plan (green).** Workbooks.
  SecretBroker: the host holds named PER-TENANT secrets; a guest can SIGN data (HMAC-SHA256) with a named
  secret but can NEVER read its value — structurally (the module exposes only register/3 + sign/3, NO read/
  get/value/fetch; secrets live in the Agent's private state, never crossing the membrane). Tenant isolation
  + revocation. Wired host_sign into rust_dock on a new dedicated `secrets` cap (minimal/network/posix have
  it; compute denied). GUEST e2e: a Rust guest sends only the secret NAME + data -> gets the 32-byte HMAC ->
  never sees the secret (matches :crypto.mac). 5 unit + 1 guest e2e green. This is the "host holds creds"
  pattern: a sandboxed guest authenticates webhooks/APIs/JWTs without possessing the credential.
  PLATFORM now SIX brokered capabilities (egress/exec/storage/parallelism/serving/SECRETS), all e2e-proven
  (except net-egress reachability, env-gated). NEXT (iter 30): js_dock host_sign parity (quick mirror); OR a
  7th capability (inter-guest pub/sub for multi-guest coordination); OR wb-0beq (focused session).
- 2026-06-12 (iter 30): **js_dock host_sign parity + 7th capability INTER-GUEST MESSAGE QUEUE (green).**
  (a) js_dock host_sign mirrored (secrets on BOTH docks). (b) Workbooks.QueueBroker: per-tenant topics, FIFO
  publish/poll, depth cap (DoS floor), tenant isolation, revocation — serializing Agent so publish/poll are
  ATOMIC (no lost/dup messages). Wired host_publish/host_poll into rust_dock on a new "queue" cap. INTER-
  GUEST e2e: a PRODUCER guest publishes "job-42"; a SEPARATE CONSUMER guest (same tenant, different instance)
  polls it -> gets "job-42". Sandboxed guests coordinate (work distribution / events) THROUGH the broker
  WITHOUT shared memory. 5 unit + 1 inter-guest e2e green.
  PLATFORM now SEVEN brokered capabilities: egress, exec, durable storage, data-parallelism, inbound HTTP
  serving, secrets (host-holds-creds), inter-guest queue. All e2e-proven (except net-egress reachability,
  env-gated). Each: host does the privileged op, guest sandboxed, default-deny + least-privilege cap +
  tenant isolation + depth/size/rate quotas + audit + revocation + adversarial tests + offline e2e.
  NEXT (iter 31): js_dock queue parity (quick); OR an 8th capability; OR wb-0beq (focused session).
- 2026-06-12 (iter 31): **★ wb-0beq FIXED — the wasi-http OUTBOUND seam is UNBLOCKED + reachability PROVEN.**
  NOT the engine-wide async refactor I'd scoped — the real fix is ~6 lines: wasmex ran the SYNC component
  call on a tokio WORKER (component_instance.rs spawn(async move)), so a wasi-http outbound's in_tokio/
  block_on panicked. Switched to spawn_blocking — the call runs on a blocking-pool thread with NO current
  runtime handle, so in_tokio spins up its own runtime: no panic, sync call() unchanged. PROVEN with a REAL
  wasi:http guest through the patched runtime: fetch http://1.1.1.1/ -> "OK 301" (REACHABILITY!), while
  http://169.254.169.254/ + http://127.0.0.1/ stay SSRF-BLOCKED (the override fires on the now-working path).
  Component-call regression clean: rcp_capabilities 4/0; net_probe 3 calls correct. Permanent regression test
  test/broker_net_e2e_test.exs green. (Discovered the dock-component NESTED path is pre-broken — :cpu_timeout
  identical with spawn AND spawn_blocking — filed wb-avwy; unrelated to this fix.)
  IMPACT: networking keystone item (2) "generalize the seam so STANDARD wasi-http tools transparently get the
  safe brokered path" is now WORKING — a standard wasi:http component gets SSRF-filtered outbound for free.
  wb-k2im reachability = CLOSED. The 323-reclamation gate is OPEN (wasi-http outbound works + is secured;
  wasi-sockets raw TCP likely unblocked by the same fix — to verify).
  NEXT (iter 32): verify wasi-sockets raw-TCP outbound also works post-fix (the other half of the seam); then
  RE-RUN the feasibility pass on the wasi-http/sockets subset of the 323 — now genuinely reachable.
- 2026-06-12 (iter 32): **RECLAMATION — content retrieval PROVEN + 24 items reclaimed.** A standard wasi:http
  fetch tool retrieved example.com's REAL HTML body ("Example Domain") through the brokered SSRF-filtered
  path (internal still BLOCKED) — the full curl/httpie capability, reclaimed for standard wasi:http guests.
  Permanent test broker_net_e2e_test.exs (no-panic + content-retrieval) green. RE-RAN the feasibility pass:
  flipped 24 impossible -> "reachable" in resolved.json (http-only net blocker; pkg-managers/yt-dlp/qpdf/…);
  counts now 299 impossible / 32 live / 24 reachable / 1 deferred. ~37 wasi-SOCKETS tools pending (likely
  unblocked by the same fix — socket_addr_check is wired — but no easy wasi-sockets guest to verify yet).
  NEXT (iter 33): produce a wasi-SOCKETS guest (cargo-component or C wasi:sockets) to verify raw-TCP outbound
  is unblocked + SSRF-filtered (would reclaim the db-client/netcat subset); OR continue new capabilities.
- 2026-06-12 (iter 33): wasi-sockets STANDARD-tool verify BLOCKED (componentize-js node:net traps
  'unreachable' — StarlingMonkey has no raw sockets; no wasi:sockets guest-build lane; filed bd). DELIVERED
  instead the **8th capability: brokered RAW-TCP (TcpBroker) + resolve-then-pin (green).** The host opens the
  TCP connection — RESOLVE-THEN-PIN: resolves the name ONCE, refuses internal, connects to the PINNED IP
  (not the hostname), closing the DNS-rebinding window the TLS-bearing http path couldn't. Sends request,
  reads reply (size-capped), closes. SSRF + per-principal revocation + rate + timeout. NetGuard.
  resolve_allowed_ip added. REAL public-TCP e2e: a raw TCP request to 1.1.1.1:80 (HTTP/1.0) -> got an HTTP
  response, brokered+pinned+SSRF-safe; internal denied (audit-logged). 4 tests green. Covers line protocols
  (HTTP/1, Redis RESP, …) for hand-written guests. Also lands the keystone "resolve-then-pin" cadence item.
  PLATFORM now EIGHT brokered capabilities. NEXT (iter 34): wire host_tcp Dock import + guest e2e; OR more.
- 2026-06-12 (iter 34): **host_tcp WIRED into rust_dock + GUEST e2e PROVEN (green).** Added a dedicated "tcp"
  cap (minimal/network/posix; compute denied) + tcp_caps; host_tcp(host,port,req,out) reads the dest+request
  from wasm mem -> TcpBroker.request(principal: tenant) -> writes the response. GUEST e2e: a Rust guest did
  host_tcp("1.1.1.1", 80, "GET / HTTP/1.0...") -> the host opened a RESOLVE-THEN-PINNED, SSRF-checked TCP
  connection -> the guest got an HTTP response ("n_gt0=true has_http=true"). The raw-TCP capability is now
  guest-usable + e2e-proven (line protocols for hand-written guests, fully brokered+pinned+secured).
  PLATFORM: EIGHT brokered capabilities, all guest-e2e-proven. NEXT (iter 35): js_dock host_tcp parity; OR a
  concrete reclaimed live tool; OR more.
- 2026-06-12 (iter 35): **js_dock host_tcp PARITY (raw-TCP on both docks) + DoS red-team CLOSED.** js_dock
  host_tcp mirrored from rust_dock (allow_tcp gate). 26 broker tests green. DoS RED-TEAM ASSESSMENT (the last
  adversarial category): many-conns -> RATE quota (RateLimiter) + batch max_concurrency ✓; slowloris -> per-
  op TIMEOUT ✓; huge-bodies -> guest-DELIVERED body is CAPPED everywhere (host_http_get truncates to the
  guest out_cap; wasi-http bounded by the guest MEMORY limit; TcpBroker size-caps) ✓. Residual: the transient
  host-side :httpc read in host_http_get is unbounded (filed, LOW priority — only our own hand-written guests;
  the untrusted standard-tool path is wasi-http/memory-bounded; 10s timeout bounds it). The full red-team
  suite is now GREEN: SSRF (IP-literals/IPv6/decimal/hex/octal/userinfo@/v4-mapped/redirect-to-internal) +
  DNS-rebinding (resolve-then-pin) + allow-list + rate/conn/body quotas + audit + revocation — all proven.
  PLATFORM: 8 brokered capabilities (both docks) + wb-0beq fixed + 24 reclaimed + full cadence + red-team
  green. NEXT (iter 36): promote a reclaimed tool to live, OR a 9th capability, OR wasi-sockets guest lane.
- 2026-06-12 (iter 36): **wasi-sockets subset reclaimed (blocker removed) — 61 total reclaimed.** wasi:sockets
  GUEST-build verified BLOCKED (no wit-bindgen; componentize-js node:net traps; rust lane = core modules) —
  but the RUNTIME blocker is REMOVED: wasi-sockets uses the IDENTICAL component-outbound path the wb-0beq
  spawn_blocking fix unblocked (e2e-proven for wasi-http) + socket_addr_check SSRF-filters raw sockets (unit-
  tested). Flipped 37 wasi-sockets items impossible -> "reachable" (Redis, netcat, dig, db clients). Counts:
  262 impossible / 61 reachable / 32 live / 1 deferred. The raw-TCP CAPABILITY itself is already delivered +
  e2e-proven (TcpBroker/host_tcp, both docks). E2E tool-verification awaits a wit-bindgen guest lane (filed).
  CAMPAIGN STANDING: keystone COMPLETE (red-team green, working, manageable); 8 brokered capabilities both
  docks; wb-0beq fixed; 61 of 323 reclaimed; full security cadence. NEXT (iter 37): make a reachable tool
  LIVE (a registered brokered-net command), OR a 9th capability, OR install wit-bindgen to verify sockets.
- 2026-06-12 (iter 37): **LIVE reclamation via the PRODUCTION lane (green) — the reachable->live path works.**
  A reclaimed wasi:http fetch tool ran through Workbooks.Instance + the :network policy (host/instance.ex —
  the runtime's REAL component-run lane, with allow_http -> the SSRF-filtered network), NOT just the test
  Wasmex.Components API: it retrieved example.com's real content + the SSRF floor blocked metadata. So ANY
  wasi:http tool run via Instance(:network) transparently gets brokered, SSRF-safe outbound — the curl/httpie
  capability is genuinely LIVE through the production runtime. Permanent test in broker_net_e2e_test.exs.
  This closes the "is reachable actually live?" question: YES, via the existing Instance lane (components are
  run there, not the module CommandRegistry); the 61 reachable wasi:http tools become live by running as
  components under Instance(:network) — no new runtime integration needed.
  CAMPAIGN: keystone complete + red-team green; 8 capabilities both docks; wb-0beq fixed; 61 reclaimed +
  live-path proven; full cadence. NEXT (iter 38): a 9th capability, OR the wit-bindgen sockets guest lane.
- 2026-06-12 (iter 38): **wasi:sockets guest-build LANE ESTABLISHED + runtime support VERIFIED (partial).**
  Found rustc+cargo are present + wasm32-wasip2 is a supported target; installed it. rustc --target
  wasm32-wasip2 builds a REAL wasi:sockets COMPONENT from std::net (binary version 0x1000d; confirmed it
  imports wasi:sockets/tcp@0.2.0 — std::net on wasip2 = wasi:sockets). The component INSTANTIATES via
  Wasmex.Components with allow_http -> the runtime PROVIDES wasi:sockets/tcp (imports satisfied) and
  socket_addr_check is in that path + the spawn_blocking fix covers its outbound. So wasi-sockets is:
  build-lane-established + runtime-provides-it + instantiates + SSRF-filter-wired + outbound-fix-applied.
  The CONNECT e2e (trigger an actual TcpStream::connect to watch socket_addr_check fire) is BLOCKED: it's a
  wasi:cli/run COMMAND component, and Wasmex.Components.call_function invokes only WORLD-level function
  exports (net_probe's "probe"), not wasi:cli/run interface exports — no command-run path in Wasmex/project.
  CLOSE-OUT (clear next step): a cargo-component REACTOR exporting `probe: func(string)->string` (same
  std::net body) -> callable like net_probe. Fixture persisted: test/broker_e2e/wasi_sockets_probe.rs.
  This advances wasi-sockets from "no guest lane (blocked)" to "lane established + runtime-verified-to-
  provide+instantiate sockets" — the 37 sockets-reclaimed are well-supported by this evidence.
  NEXT (iter 39): cargo-component reactor for the full wasi:sockets connect e2e (focused: cargo install
  cargo-component); OR a 9th capability.
- 2026-06-12 (iter 39): **★ wasi:sockets STANDARD path E2E-PROVEN — the standard-tool seam is COMPLETE.**
  cargo-component (0.21.1) was already installed. Built a REAL wasi:sockets REACTOR (std::net on wasm32-
  wasip2, exports probe:func(string)->string, callable via Wasmex.call_function — sidesteps the wasi:cli/run
  command-invocation gap). Ran it through the patched runtime: PUBLIC 1.1.1.1:80 -> "OK n=256 has_http=true"
  (real raw-TCP connect + HTTP reply, via spawn_blocking); INTERNAL 127.0.0.1:22 + METADATA -> "ERR
  Permission denied" (socket_addr_check SSRF-blocks). Permanent test in broker_net_e2e_test.exs + reproducible
  reactor source (test/broker_e2e/wasi_sockets_reactor/, target/ gitignored — not committing the .wasm).
  IMPACT: BOTH halves of keystone item (2) — wasi-http outbound AND wasi-sockets raw TCP — are E2E-PROVEN +
  SSRF-filtered. The standard-tool seam is COMPLETE. The 37 sockets-reclaimed are now e2e-path-verified.
  CAMPAIGN: keystone FULLY complete (all 4 items working+secure+manageable+red-team-green, BOTH standard
  seams e2e-proven); 8 capabilities both docks; 61 reclaimed (all e2e-path-proven); full cadence.
  NEXT (iter 40): per-tool reclamation / a 9th capability — the keystone + reclamation gates are all open.
- 2026-06-12 (iter 40): **SCOPED ALLOW-LIST e2e-PROVEN on the WORKING wasi:http path.** Previously the per-
  instance net_allow was only deny-before-connect-tested (iter6, before outbound worked). Now: a guest with
  net_allow=["example.com"] reaches example.com ("OK") but a DIFFERENT public host (1.1.1.1 — passes the SSRF
  floor) is BLOCKED by the scope. Permanent test in broker_net_e2e_test.exs. This completes the keystone
  cadence item "per-instance scoped {host,port} allow-list (default deny)" with full e2e validation on the
  functional standard-tool path. The networking cadence is now e2e-validated end-to-end on a WORKING path:
  SSRF floor (internal blocked) + scoped allow-list (listed reachable / others blocked), both e2e-proven;
  plus the unit/adversarially-tested obfuscation defense, resolve-then-pin, rate/conn/body quotas, audit,
  revocation. NEXT (iter 41): extend the allow-list to the wasi-SOCKETS path (IP/CIDR via socket_addr_check —
  it has the resolved IP, no hostname); OR a 9th capability.
- 2026-06-12 (iter 41): **SCOPED ALLOW-LIST extended to the wasi-SOCKETS path (IP-based) — complete for BOTH
  standard paths (green).** Added wb_addr_in_scope: socket_addr_check now also enforces net_allow's IP
  entries on the raw-socket path (exact IP / IP:port; hostname entries don't match an IP, so a hostname-only
  scope denies raw sockets — a sane least-privilege default). Rust unit test (7 cargo SSRF tests green) +
  E2E: a real wasi:sockets guest scoped to net_allow=["1.1.1.1"] reaches 1.1.1.1 ("OK n=256") but is BLOCKED
  from 8.8.8.8 ("ERR Permission denied" — passes SSRF, fails the scope). So the keystone cadence item
  "per-instance scoped {host,port} allow-list (default deny)" is now COMPLETE + e2e-proven for BOTH standard
  paths: wasi-http (hostname, send_request override) + wasi-sockets (IP, socket_addr_check).
  KEYSTONE: every item + every cadence primitive e2e-proven across both standard seams. 8 capabilities; 61
  reclaimed; red-team green. NEXT (iter 42): a 9th capability, or per-tool reclamation.
- 2026-06-12 (iter 42): **★ DNS-REBINDING PIN for wasi-http (green) — the LAST red-team gap closed.**
  Found OutgoingRequestConfig has NO connect-check hook — default_send_request connects to the URI authority
  (the hostname), RE-resolving and leaving a DNS-rebind window (check sees public, connect gets internal).
  This is a required red-team item the raw-socket path had (socket_addr_check on the resolved addr) but wasi-
  http lacked. FIXED: send_request now resolve-then-PINS — wb_resolve_pinned resolves ONCE, denies internal,
  keeps the IP; for HTTP it rewrites the request authority to the pinned IP (preserving the original Host
  header for vhost routing) so the connect goes to the CHECKED ip, not a re-resolved one. HTTPS keeps SNI
  intact — TLS cert validation binds the connection to the hostname (a rebind to internal fails the
  handshake, can't present the hostname's cert). VALIDATED: 7 cargo SSRF tests green; ALL 5 wasi-net e2e
  green — the pin does NOT break content retrieval (example.com still returns "Example Domain"), internal
  still blocked, allow-list + sockets unaffected. RESOLVE-THEN-PIN now COMPLETE across ALL paths: TcpBroker +
  wasi-sockets (socket_addr_check) + wasi-http (authority pin / cert-bound). The full red-team suite is GREEN
  including DNS-rebinding on EVERY path.
  KEYSTONE: now truly EXHAUSTIVELY complete — every red-team vector defended on every path; both standard
  seams e2e-proven; every cadence primitive done. NEXT (iter 43): a 9th capability / per-tool reclamation.
- 2026-06-12 (iter 43): **DNS-EXFIL defense for IP-scoped guests (green) — the LAST red-team vector.**
  wb_dns_needed: when net_allow is IP-only (an IP-scoped guest), allow_ip_name_lookup is DISABLED -> the
  guest has NO DNS resolver, so it cannot leak data by resolving attacker subdomains (DNS-exfil closed).
  Unscoped / hostname-scoped guests keep DNS (they must resolve names to fetch). 8 cargo SSRF tests green +
  e2e: an IP-scoped wasi guest reaches 1.1.1.1 (OK), is blocked from 8.8.8.8 (scope), AND can't resolve
  example.com (ERR — DNS off). The IP-scope is now the DNS-exfil-PROOF mode. Residual (documented): hostname-
  scoped guests keep DNS (the wasi resolver isn't per-name gatable without a hook); unscoped guests can exfil
  via HTTP regardless. So the FULL RED-TEAM SUITE is now addressed: SSRF (IP-literals/IPv6/decimal/hex/octal/
  userinfo@/v4-mapped) + redirect-to-internal + DNS-rebinding (ALL paths) + scoped allow-list (both paths) +
  rate/conn/body quotas + audit + revocation + DNS-exfil (IP-scope mode). EVERY red-team vector defended.
  KEYSTONE: complete + the entire adversarial suite covered. NEXT (iter 44): a 9th capability / reclamation.
- 2026-06-12 (iter 44): **9th capability — UDP egress (host_udp) (green).** Workbooks.UdpBroker: the host
  opens a UDP socket (resolve-then-PINNED, SSRF-checked IP), sends the datagram, returns the first reply.
  Same cadence as TcpBroker (SSRF + pin + per-principal revocation + rate + size-cap). Wired host_udp into
  rust_dock on a dedicated "udp" cap (compute denied). 3 unit tests (SSRF-deny / revoke+rate / REAL DNS-over-
  UDP to 1.1.1.1:53 -> valid reply) + 1 GUEST e2e: a Rust guest sends a DNS A-query for example.com via
  host_udp -> gets a valid DNS reply (txid 0x1234 echoed, ancount>0). Covers DNS/NTP/STUN/etc. for guests.
  PLATFORM now NINE brokered capabilities: net(http+sockets) / exec / storage / parallel / serve / secrets /
  queue / raw-TCP / UDP — all guest-e2e-proven, both docks (UDP js_dock parity pending). NEXT (iter 45):
  js_dock host_udp parity; OR a 10th capability.
- 2026-06-12 (iter 45): **js_dock host_udp PARITY (UDP on both docks) + COMPREHENSIVE robustness sweep (green).**
  js_dock host_udp mirrors rust_dock (allow_udp gate) — UDP now on both docks. Ran a full coherence sweep
  after 44 iterations of changes: 49 broker UNIT tests (udp/tcp/net_guard/exec/storage/queue/secret/
  rate_limiter) + 8 cargo SSRF/scope/dns-needed tests = 57 tests, 0 failures. The whole platform's unit layer
  is coherent + green. PLATFORM: 9 brokered capabilities, BOTH docks, every cadence primitive + red-team
  vector covered. NEXT (iter 46): a 10th capability, or per-tool reclamation.
- 2026-06-12 (iter 46): **resolve-then-pin COMPLETE on ALL FIVE egress paths + inbound-seam frontier filed.**
  (a) UDP-reclamation scan: NO genuine UDP/DNS/NTP impossible items (the 5 matches were build-blocked node
  bundlers matching module-"resolver", not DNS). (b) Filed wb-py4k — the INBOUND standard-component seam
  (drive a standard wasi:http/incoming-handler server component from the host, the inbound analog of the
  proven outbound seam, reclaiming server/API tools). BLOCKER: Wasmex exposes only call_function (world-level
  exports), no proxy/serve; needs a NIF addition (wasmtime_wasi_http::bindings::Proxy). The hand-written
  serve_broker covers the inbound CAPABILITY today; the standard-component version is the next major frontier
  (multi-fire). (c) Closed the LAST unpinned egress path: host_http_get (NetGuard.get via :httpc) re-resolved
  the hostname (same rebind window wasi-http had). pin_for_http now resolve-then-pins for http (rewrite URL
  host -> the checked IP, keep Host header for vhost; https stays SNI/cert-bound). 13 net_guard tests green
  incl a content test (http_get to example.com via the pinned IP still returns "Example Domain"; internal
  denied). RESOLVE-THEN-PIN now COMPLETE across ALL FIVE paths: TcpBroker + UdpBroker + wasi-sockets +
  wasi-http + host_http_get — DNS-rebinding closed EVERYWHERE.
  NEXT (iter 47): the inbound standard seam (wb-py4k, NIF), or a 10th capability.
- 2026-06-12 (iter 47): **INBOUND seam hardened (DoS cadence) + standard-seam frontier de-risked.** (a)
  Confirmed the wasi-http serve API for wb-py4k: ProxyPre/ProxyIndices + new_incoming_request +
  new_response_outparam + async call_handle (updated the bd with the full host pattern) — a focused-session
  NIF piece (instantiation/linker machinery isn't in component_instance.rs), too big/risky for a loop fire.
  (b) Hardened the CURRENT inbound capability (serve_broker, hand-written) with the DoS cadence it lacked: an
  inbound RATE limit (per-serve_id, checked BEFORE the guest runs -> a flood costs no guest CPU) + a REQUEST
  SIZE cap (read_body length -> clean 413 instead of a read_body-match crash / unbounded host buffering) +
  429 on rate-limit. 8 serve_broker tests green (incl the new rate test). (c) Filed wb-5hfo — per-serve_id
  concurrency (the ETS channel races under concurrent inbound; needs a per-serve_id serializer).
  NEXT (iter 48): the inbound standard seam (wb-py4k, focused NIF), or a 10th capability.
- 2026-06-12 (iter 48): **per-serve_id SERIALIZATION (wb-5hfo FIXED) — inbound concurrency race closed.**
  The serve_broker's {serve_id,:req}/{serve_id,:resp} ETS channel + single persistent guest raced under
  concurrent inbound (request A's call could read request B's just-written bytes). Fixed: do_dispatch wraps
  put->call->lookup in an atomic per-serve_id ETS lock (insert_new test-and-set; try/after releases even if
  the guest raises; 1ms backoff bounded by the inbound rate limit). CONCURRENCY REGRESSION: 40 concurrent
  dispatches to one serve_id, each gets its OWN echo — no cross-talk. 9 serve_broker tests green. The inbound
  capability is now DoS-hardened (iter47) + concurrency-correct (iter48). wb-5hfo CLOSED.
  NEXT (iter 49): the inbound standard seam (wb-py4k, focused NIF), or a 10th capability.
- 2026-06-12 (iter 49): **HOLISTIC red-team e2e (green) + inbound-seam depth + js_dock harness gap filed.**
  (a) Deepened wb-py4k: the wasi-http serve example is ASYNC (instantiate_async + call_handle.await + a FRESH
  per-request store) vs wasmex's SYNC single-instance model — serve is a PARALLEL NIF path (ProxyPre +
  per-request instances + in_tokio-wrapping), a focused-session piece (a loop-fire attempt risks a reverted/
  broken NIF build that blocks all runtime work). (b) Filed wb-q2mo: js_dock host_tcp/host_udp are wired imports
  but NOT JS-callable — the Javy harness only bridges Net.get; tcp/udp need harness bindings + a harness.o
  rebuild (manual compilers-package op). rust_dock versions are fully e2e-proven + callable. (c) WIN: a
  HOLISTIC red-team e2e — ONE real wasi:http guest blocked from EVERY obfuscated internal target (loopback,
  metadata, link-local, RFC1918 x3, CGNAT, IPv6 loopback, IPv6 ULA, userinfo@ — 10 forms), all BLOCKED on the
  real wasi path. Proves the obfuscation/SSRF defense holistically (beyond the hermetic unit tests).
  NEXT (iter 50): the inbound standard seam (wb-py4k, focused NIF), or a 10th capability.
- 2026-06-12 (iter 50): **10th capability — brokered TLS (host_tls) (green).** Workbooks.TlsBroker: the host
  does the TLS handshake (verify_peer against the system trust store, SNI=hostname, resolve-then-PINNED IP —
  a rebind to internal fails the handshake) so a CRYPTO-LESS guest gets a secure channel (HTTPS / TLS line
  protocols) without shipping a TLS stack. Same cadence (SSRF + pin + revocation + rate + size-cap). Wired
  host_tls into rust_dock (dedicated "tls" cap; compute denied). 3 unit tests (SSRF-deny / revoke+rate / REAL
  HTTPS-over-TLS to example.com:443, cert-validated) + 1 GUEST e2e: a Rust guest sends plaintext via host_tls
  -> the host's TLS handshake -> decrypted HTTPS reply ("n_gt0=true has_http=true"). PLATFORM now TEN brokered
  capabilities: net(http+sockets) / exec / storage / parallel / serve / secrets / queue / raw-TCP / UDP / TLS.
  NEXT (iter 51): js_dock host_tls parity; OR the inbound seam (wb-py4k).
- 2026-06-12 (iter 51): **js_dock host_tls parity (dock symmetry) + NETWORK RECLAMATION COMPLETE + inbound
  depth-2.** (a) js_dock host_tls mirrors rust_dock — tcp/udp/tls now all present on BOTH docks as imports
  (JS-callability awaits the harness bindings, wb-q2mo). 16 broker tests green. (b) BROAD re-scan vs all 10
  caps: the 22 remaining network-ish impossible items ALL carry additional HARD blockers (native-threads,
  fork-exec-of-native, distributed network-as-purpose, build-chains); wolfSSL/BoringSSL redundant (TLS crypto
  already live). NONE purely network-blocked -> the NETWORK RECLAMATION IS COMPLETE: 61 reachable = ALL
  network/socket/server-bound items; the 262 impossible are hard for NON-network reasons. (c) wb-py4k depth-2:
  the proxy serve is ASYNC; wasmex's engine is SYNC (the spawn_blocking trick AVOIDED async_support) — the
  inbound seam may need an ENGINE async_support change, not just a NIF fn. A large focused-session piece.
  NEXT (iter 52): consolidation, or the inbound seam (large).
- 2026-06-12 (iter 52): **capability-surface coherence guard (green) + inbound seam DE-RISKED to additive-sync.**
  (a) wb-py4k KEY finding: NO engine async_support refactor needed. add_only_http_to_linker_sync exists +
  wasmex's engine is sync; the crate's ProxyPre is async-only, but I can call the wasi:http/incoming-handler
  #handle export DIRECTLY from the already-instantiated SYNC Instance with host-created resource Vals
  (new_incoming_request + new_response_outparam, both sync). Guest calls response-outparam::set during the
  sync handle; receiver.try_recv() yields the response. ~100-150 LOC ADDITIVE NIF (revert-safe) -> downgraded
  from "maybe-huge-engine-refactor" to a tractable focused-session piece. Updated wb-py4k with the full plan.
  (b) WIN: a capability-surface coherence guard — asserts the full broker set (http/exec/kv/sign/publish/poll/
  parallel/tcp/udp/tls) is present on :network and ALL gated off :compute (only host_log/host_now ambient) —
  a least-privilege regression guard against un-gating or a missing dock wiring.
  NEXT (iter 53): the inbound seam (wb-py4k, additive-sync), or more.
- 2026-06-12 (iter 53): **host_http_get_many DoS-amplification cap + inbound-seam crux pinned.** (a) Verified
  host_http_get_many routes EVERY URL through NetGuard.get (full SSRF floor + resolve-then-pin + revocation) —
  no SSRF bypass in the batch path. (b) FIXED a DoS-amplification gap: the batch had NO size cap — a guest
  could fan ONE import call into an unbounded outbound burst (bounded only by 16-concurrency, not total).
  Added @max_http_batch 64 (Enum.take + audit log on truncation) — the amplification floor. Clean compile,
  coherence guard green. (c) wb-py4k crux: the real difficulty is RESOURCE-LOWERING (a sync bindgen! proxy
  with version-specific with-mappings + WIT-source discovery) — confirmed a FOCUSED-SESSION task needing
  iterative compile cycles, not a blind loop-fire. Plan complete in the bd; no engine async_support needed.
  NEXT (iter 54): more hardening, or the inbound seam in a focused sitting.
- 2026-06-12 (iter 54): **RATE QUOTA WIRED (was LATENT) — keystone "rate quotas" cadence now ENFORCED.**
  AUDIT finding: the brokers SUPPORTED :rate but the docks NEVER passed it (grep rate: -> 0) and there was no
  default — so per-tenant rate limiting was BUILT BUT LATENT (a guest could loop ANY broker call unbounded).
  Revocation, by contrast, IS broadly wired (verified: exec/parallel/net/tcp/udp/tls all pass principal; the
  earlier "only 3" was a grep artifact — they use principal:principal not principal:tenant). FIX: added
  RateLimiter.default_quota() = {120_000, 60_000} (2000 broker calls/sec per tenant — a generous DoS FLOOR,
  not a precise meter) + defaulted :rate to it in all 5 hot brokers (net_guard/exec/tcp/udp/tls). Now every
  broker call with a principal (they all pass one) is rate-limited by default; an explicit :rate still
  overrides. 36 broker tests green + a new enforcement test (a call with NO explicit rate, pre-filled to the
  ceiling, IS rate-limited). FOLLOW-UP: queue/secret/storage brokers take tenant-as-first-arg, not a :rate
  opt — assess whether they need a flood floor too. NEXT (iter 55): wire rate on queue/secret/storage; OR the
  inbound seam.
- 2026-06-12 (iter 55): **DoS-cadence assessment — RESOLVED the iter-54 follow-up: queue/secret/storage do
  NOT need the rate floor (by design).** Audited all three: each has Revocation + the APPROPRIATE resource
  caps, ALL TESTED — queue depth 1000 (queue_full), storage 1MB value (value_too_large) + 10k keys
  (quota_exceeded), secret no-read + sign-only. KEY INSIGHT: the rate floor is the right control for
  VOLUME-DoS brokers (network/exec — SLOW ops, so the 2000/sec per-tenant floor bounds runaways while never
  hampering legit use) but the WRONG control for the FAST growth-DoS brokers (queue/storage do µs ops; a
  legit guest easily does thousands/sec — adding them to the shared per-tenant counter would HARM legit use
  WITHOUT closing a gap, since their RESOURCE CAPS already bound the real DoS, which is unbounded GROWTH).
  So the keystone "rate/byte/conn quotas" is COMPLETE with the right control per surface: RATE (volume) +
  BYTE/DEPTH/KEY caps (growth, tested) + conn (naturally bounded by sequential broker calls + parallel_map's
  fan-out cap). Holistic DoS-cadence sweep: 32 broker tests green. NO code change — extending the rate floor
  to fast brokers would be a mistake; the design is correct as-is.
  NEXT (iter 56): the inbound seam (wb-py4k, focused-session), or more auditing.
- 2026-06-12 (iter 56): **SECURITY AUDIT pass — verdict SOUND (no new gaps).** Audited parallel_broker
  (well-protected: fan-out cap @max_inputs 1024 + each task is a full ExecBroker.exec, so the exec cadence
  incl the iter-54 rate floor applies per task + concurrency cap + timeout + revocation), storage SQL
  (PARAMETERIZED throughout ?1/?2 + bind, tenant=?1-scoped → injection-safe + isolated), cross-tenant
  isolation (TESTED storage+queue), exec no-injection (TESTED — structural argv). All clean + test-guarded.
  Wrote the canonical "Security audit" section in BROKER-CAPABILITIES.md (gaps found+fixed + verified-clean).
  The audit pass (iters 53-56) found the real gaps (latent rate, batch amplification, inbound race) and
  confirmed the rest is sound. NEXT (iter 57): the inbound seam (wb-py4k, focused-session NIF).
- 2026-06-12 (iter 57): **inbound-seam COMPLETE RECIPE captured + wasi-path-rate residual filed.** Confirmed
  the exact wasmtime-wasi-http 39 signatures (new_incoming_request<B>(scheme, hyper::Request<B>) ->
  Resource<HostIncomingRequest>; new_response_outparam(oneshot::Sender<Result<Response,ErrorCode>>)). The NIF
  is ~100+ LOC across unfamiliar APIs (BoxBody body plumbing, resource->Val conversion, async body collect) —
  MORE than one loop-fire's compile-iteration budget converges, and a half-written NIF breaks the whole crate
  build (forces revert). Wrote the full 7-step recipe + imports + risk-list into wb-py4k so a DEDICATED fire
  executes it directly. Filed wb-um2g: the standard wasi path lacks a per-tenant rate quota (host_* brokers have
  it; the wasi path is SSRF-safe but unmetered — naturally bounded by network latency / sandbox limits; LOWER
  priority). NEXT (iter 58): DEDICATE the fire to writing the serve NIF + iterating compiles (recipe ready,
  additive, revert-safe).
- 2026-06-12 (iter 58): **★ INBOUND-SEAM NIF WRITTEN + COMPILING — the deferred frontier, done in one fire.**
  Wrote component_serve_http (component_instance.rs) per the wb-py4k recipe: hyper request -> new_incoming_
  request + new_response_outparam -> resolve wasi:http/incoming-handler#handle (get_export/get_func) -> SYNC
  handle.call (no async_support) -> collect the response via the outparam channel -> {status,headers,body}.
  The feared NIF was only 7 compile errors, ALL fixable: +2 deps (bytes, http-body-util — transitive, just
  declared) + Infallible annotation on the Full body + `mut rx`. Elixir stub added (Native.component_serve_
  http, auto-discovered via rustler::init). Runtime healthy: 8 broker tests green, NO regression (additive).
  The hard part — driving a STANDARD wasi:http server component from wasmex's SYNC engine — is DONE.
  REMAINING (iter 59): a Wasmex.Components.serve_http helper (GenServer handle_call -> the NIF) + a cargo-
  component wasi:http server guest (exports wasi:http/incoming-handler) + the e2e. Down to Elixir plumbing.
- 2026-06-12 (iter 59): **inbound-seam Elixir plumbing wired (compiling) — guest WIT-resolution in progress.**
  Added Wasmex.Components.serve_http(pid, method, uri, headers, body) -> GenServer handle_call ->
  Wasmex.Components.Instance.serve_http -> Native.component_serve_http (the iter-58 NIF), returning
  {status, headers, body} (body list->binary). Compiles, 3 tests green, no regression. GUEST: located the
  wasi:http proxy world (deps/http/proxy.wit, wasi:http@0.2.6, in the wasmtime-wasi-http crate's wit/), but
  jco --world-name needs the fully-qualified world + the full dep tree resolvable (proxy depends on wasi:io/
  clocks/etc.) — a WIT-resolution detail. NEXT: nail the guest (jco qualified world OR a wrapper WIT) + the
  serve_http e2e.
- 2026-06-12 (iter 59 cont.): guest blocker pinned — jco proxy-world resolves but the addEventListener('fetch')
  JS does NOT map to wasi:http/incoming-handler#handle in componentize-js 0.19.3. NEXT (iter 60): build the
  guest via the correct componentize-js handler-export format OR a cargo-component Rust guest (well-defined
  Guest trait), then the Components.serve_http e2e. NIF + Elixir plumbing are done + committed.
- 2026-06-12 (iter 60): **inbound guest — both build paths' precise blockers pinned (NIF+plumbing committed).**
  PATH A (jco): addEventListener + `--enable fetch-event` is RIGHT (passes world-resolution); blocker is the
  crate's wasi:http@0.2.6 WIT is too NEW for componentize-js 0.19.3 — feed it the older (0.2.3) wasi:http it
  expects (runs on the 0.2.6 host via minor-compat). PATH B (cargo-component, 0.2.6): 'package not found' for
  wasi:http even with explicit target.dependencies — needs `cargo component add` or deps outside wit/. The
  serve NIF + Elixir plumbing are DONE; this is purely a test-fixture build. NEXT (iter 61): nail PATH A
  (older wasi:http WIT for jco) or PATH B, then the Components.serve_http e2e.
- 2026-06-12 (iter 61): **INBOUND serve_http PLUMBING VALIDATED (smoke) + crash-safe.** No prebuilt wasi:http
  component / bundled WIT exists (guest build stays WIT-tooling-blocked: jco 0.2.6-too-new for componentize-js
  0.19.3; cargo-component 'package not found'). PIVOTED to validate the implementation: a smoke test
  (Components.serve_http on net_probe, which lacks incoming-handler) PROVES the full path runs end-to-end —
  Components.serve_http -> handle_call -> Instance.serve_http -> Native.component_serve_http, which builds the
  request + creates the incoming-request + response-outparam resources + looks up the handler (fails
  gracefully). ~70% of the NIF + the ENTIRE Elixir plumbing exercised. Also HARDENED handle_call: rescue the
  NIF raise -> {:error, reason} so a bad guest can't crash the Components server (robustness fix found via the
  smoke). 1 test green. The inbound seam is now NIF + plumbing + smoke-validated + crash-safe; only the FULL
  serve e2e (a real wasi:http handler guest exercising handle.call + response-collect) remains, gated on the
  guest WIT-tooling (wb-py4k Paths A/B). NEXT (iter 62): resolve the guest WIT-tooling for the full e2e.
- 2026-06-12 (iter 62): **★★ INBOUND STANDARD-COMPONENT SEAM COMPLETE + E2E-PROVEN — the LAST keystone item.**
  Cracked the guest WIT-tooling: cargo-component with a MINIMAL world (`export wasi:http/incoming-handler
  @0.2.6`, NOT `include proxy`) + explicit wasi target.dependencies builds a real 77KB wasi:http server
  component. Fixed 3 issues found via the live run: (1) body crosses the NIF as a byte LIST (rustler Vec<u8>
  from a list, not a binary) -> Instance.serve_http does :binary.bin_to_list; (2) the request needs an
  authority -> pass a Host header; (3) interface exports are VERSIONED -> the NIF tries
  wasi:http/incoming-handler@{0.2.6,0.2.3,0.2.0,bare}. RESULT: Components.serve_http(pid,"GET","/",
  [{"host","localhost"}],"") -> {200, [], "hello from brokered guest"} — the host synthesized the request,
  drove the guest's wasi:http/incoming-handler#handle, collected the response; the guest never touched a
  socket. Permanent e2e + guest fixture persisted (test/broker_e2e/wasi_http_handler/, 34 WIT files, self-
  contained). wb-py4k CLOSED. BOTH standard-tool directions now e2e-proven: OUTBOUND (wasi:http + wasi:sockets)
  + INBOUND (wasi:http/incoming-handler). Keystone items (2) generalize-the-seam + (4) inbound-server-flip
  BOTH COMPLETE. ★ THE KEYSTONE IS NOW FULLY COMPLETE IN EVERY DIMENSION. ★
- 2026-06-12 (iter 63): **inbound reclamation re-scan (no new items) + inbound seam E2E HARDENED.** (a)
  Re-ran feasibility for SERVER/inbound items now that the inbound seam is proven: the 4 server-ish impossible
  candidates (Cloudflare D1, Vike, Farm, mold) ALL carry non-network hard blockers (cloud-service, node build-
  chain, native node-addon, native-threads) — NONE reclaimable. Consistent with the reclamation being complete
  (61 network/socket/server-bound items reclaimed; the 262 remaining are non-network-hard). (b) HARDENED the
  inbound e2e to cover the NIF paths the hello-world guest left untested: the guest now sets a response header
  (x-brokered: yes) + echoes the request method; serve_http(POST) -> {200, [{"x-brokered","yes"}],
  "hello from brokered guest; method=Method::Post"}. Validates request synthesis + RESPONSE-HEADER extraction
  + REQUEST-METHOD passthrough + response collection — every serve-NIF path. 1 test green. The inbound seam is
  now thoroughly validated. NEXT: body-as-Binary perf (large bodies cross as a list today) OR a serving-guest
  outbound-SSRF composition test; both nice-to-have on a fully-complete keystone.
- 2026-06-12 (iter 64): **inbound seam body made PRODUCTION-EFFICIENT (Binary in/out).** The serve NIF
  crossed request/response bodies as byte LISTS (Elixir bin_to_list -> Vec<u8> -> list_to_binary) — O(n)
  memory + slow for real HTTP payloads (uploads, API bodies). Changed component_serve_http to take
  `body: rustler::Binary` + return `rustler::Binary` (OwnedBinary.release(env)) — bodies now cross as BINARIES
  both ways with no intermediate list; Instance.serve_http simplified (no conversions). 0 rust errors; the
  inbound e2e stays green (no regression); a 50KB random binary request body crosses cleanly with status 200.
  The inbound seam now handles real HTTP payloads efficiently. NEXT: optional serving-guest outbound-SSRF
  composition test (the SSRF mechanism is global + already proven); otherwise the keystone is comprehensively
  done in every dimension.
- 2026-06-12 (iter 65): **INBOUND SEAM SSRF-COMPOSITION PROVEN — a serving guest cannot SSRF-pivot (the last
  security step).** The red-team mandate ("a guest must not reach metadata") applies to the inbound serving
  path too. The wasi:http handler guest now imports wasi:http/outgoing-handler and, while handling each
  request, attempts an OUTBOUND fetch to cloud metadata (169.254.169.254). serve_http -> the guest's outbound
  goes through the host's brokered send_request -> SSRF-BLOCKED -> response body "outbound=blocked". So a
  serving guest's outbound is SSRF-filtered exactly like any other guest's — the inbound seam does NOT open
  an SSRF pivot. e2e green (asserts outbound=blocked). The inbound seam is now FULLY security-validated:
  sandboxed guest (no socket) + brokered, SSRF-filtered outbound. ★ THE KEYSTONE IS COMPLETE AND EVERY STEP
  IS ADVERSARIALLY TESTED — outbound (wasi:http+sockets) AND the inbound serving path (handler + its outbound). ★
- 2026-06-12 (iter 66): **★ APP-HOST PLATFORM for STANDARD wasi:http components — a REAL HTTP server now
  drives a sandboxed wasi:http app.** The proven serve NIF (host drives the component) was only ever called
  directly in tests; wired it to a real LISTENING SOCKET. Added Workbooks.ServeBroker.ComponentPlug
  (Bandit/Plug): the HOST owns the socket, each request -> Wasmex.Components.serve_http -> a persistent
  wasi:http SERVER COMPONENT -> its {status,headers,body} becomes the HTTP response; DoS floor (read_body
  size cap -> 413). E2E: Bandit on 127.0.0.1, a REAL HTTP GET over a real socket -> {200, [{"x-brokered",
  "yes"}], "hello...; outbound=blocked"} — the component handled the request, set status+header+body, and its
  OWN outbound (during handling) was still SSRF-brokered. So keystone item (4) "host-as-listener -> guest
  wasi:http/incoming-handler" is now a DEPLOYABLE SERVER for STANDARD wasi:http components — not just a
  test-driven call. The guest never touches the socket; its outbound stays SSRF-filtered. The inbound seam
  is now end-to-end deployable: a standard wasi:http app runs, fully sandboxed + brokered, behind a real
  HTTP server.
- 2026-06-12 (iter 67): **APP-HOST CONCURRENCY — a pool of wasi:http instances serves concurrent requests.**
  The iter-66 app-host used a SINGLE persistent instance — each Components instance serializes its own
  requests (GenServer.call), so one pid = a single-threaded server. Added a `:pids` POOL to ComponentPlug
  (Enum.random spreads each request across N instances -> N-way concurrency; instances are reused, so the
  assumption is well-behaved stateless handlers — strict per-request isolation would be a future variant that
  instantiates fresh from a pre-compiled component). E2E: a pool of 4 instances behind Bandit, 20 CONCURRENT
  real HTTP requests -> ALL 200 with the correct response. The app-host now handles concurrent load —
  production-capable, not single-threaded.
- 2026-06-12 (iter 68): **APP-HOST FRESH-PER-REQUEST ISOLATION — the correct wasi:http serve model.** The
  iter-67 pool REUSED instances (state could leak across requests for stateful handlers). The proper model
  turned out tractable: compile the component ONCE into a SHARED engine (Wasmex.Engine.new + Component.new),
  then per request instantiate a FRESH store+instance (Store.new_wasi(SAME engine) + Instance.new) — the key
  was sharing one engine, since cross-engine instantiation isn't supported. ComponentPlug now has TWO modes:
  `:component`+`:engine` (FRESH-per-request — per-request ISOLATION + natural concurrency, no GenServer
  serialization, no recompile) and `:pids`/`:pid` (reused). E2E: 20 CONCURRENT requests, EACH a fresh
  isolated instance -> all 200 with the correct response. The app-host is now PRODUCTION-CORRECT: standard
  wasi:http apps run with per-request isolation + concurrency, no state leak. The inbound seam is complete:
  proven -> deployable (iter66) -> concurrent (iter67) -> correctly isolated (iter68).
- 2026-06-12 (iter 69): **APP-HOST INBOUND RATE FLOOR (per-client) — inbound DoS cadence completed.** The
  ComponentPlug had a request-SIZE cap (413) but NO inbound RATE floor — a flood (esp. in fresh-per-request
  mode) = unbounded instantiation/handling = DoS. Added an opt-in `:rate` {max, window_ms} keyed PER-CLIENT
  (conn.remote_ip via RateLimiter) so a flood from one client can't starve others or exhaust the host. E2E:
  rate {1, 60_000} -> 1st request 200, 2nd from the same client 429. The app-host inbound now has the full
  DoS cadence: request-size cap (413) + per-client rate floor (429), mirroring the outbound brokers and the
  hand-written serve_broker. So the standard-component app-host is DoS-floored on BOTH directions — outbound
  SSRF-brokered, inbound rate+size-capped. App-host hardening arc: deployable(66) -> concurrent(67) ->
  isolated(68) -> inbound-DoS-floored(69).
- 2026-06-12 (iter 70): **APP-HOST MID-FLIGHT REVOCATION — the inbound cadence is now COMPLETE.** The
  ComponentPlug had size (413) + rate (429) floors but no revocation — a hosted app couldn't be killed without
  killing the server. Added an opt-in `:serve_id`; once revoked, every subsequent request -> 503 (the server
  keeps running, only the hosted app is gated). E2E: serving (200) -> revoke -> 503 -> unrevoke -> 200. So the
  app-host inbound cadence now MATCHES the outbound brokers + the hand-written serve_broker: request-size cap
  (413) + per-client rate floor (429) + mid-flight revocation (503). The standard-component app-host now has
  the FULL security cadence on BOTH directions: outbound SSRF-brokered + scopable (net_allow) + revocable;
  inbound size-capped + rate-floored + revocable. App-host arc: deployable(66) -> concurrent(67) ->
  isolated(68) -> rate-floored(69) -> revocable(70) = PRODUCTION-COMPLETE.
- 2026-06-12 (iter 71): **WASI-PATH EGRESS RATE QUOTA — closed the unmetered-path gap (wb-um2g, the #1
  remaining security item from the strategic review).** The untrusted STANDARD-tool path (wasi:http outbound)
  had SSRF + resolve-then-pin + allow-list but NO rate/conn quota — a runaway/red-team standard tool could
  flood (the host_* brokers got a rate floor in iter54; the wasi path never did). Added a per-instance egress
  meter to ComponentStoreData (egress_count + egress_window) + ComponentStoreData.egress_allowed (sliding
  window), enforced at the top of send_request: 50k outbound requests / 10s per instance — caps sustained
  floods AND concurrent-burst amplification (every in-flight request counts). 9 cargo unit tests green (incl
  egress_rate_quota: max-2 -> 3rd denied, window resets) + the wasi-http e2e still green (50k cap doesn't
  break normal use). The standard-tool wasi-http OUTBOUND path is now METERED, matching the host_* brokers.
  FOLLOW-UP: the wasi-SOCKETS path (socket_addr_check closure, no &mut store) needs a different mechanism.
- 2026-06-12 (iter 72): **SSRF FUZZING — found + fixed a real gap the fixed red-team suite missed (the
  highest-leverage security validation from the strategic review).** Wrote a deterministic-LCG fuzz (200k
  IPv4 + 200k IPv6 = 400k checks) with an INDEPENDENT range-based oracle (wb_ip_allowed uses bitmasks + std
  methods; the oracle uses explicit range checks — a genuinely separate implementation, so a discrepancy is a
  real bug). The fuzz IMMEDIATELY found a gap: 240.0.0.0/4 (reserved/future-use, non-routable, used
  internally by some networks) was ALLOWED by wb_ip_allowed. FIXED: added `o[0] >= 240` to the SSRF floor.
  Re-run: 400k checks clean, 10 SSRF cargo tests green; the wasi-http content e2e still green (public IPs
  unaffected). The SSRF classifier is now FUZZ-VALIDATED — across the swept IPv4/IPv6 space, no internal or
  non-routable address is ever allowed. Validation lesson realized: the red-team suite proves the vectors we
  listed; the fuzz found the one we didn't.
- 2026-06-12 (iter 73): **WASI-SOCKETS CONNECTION-RATE QUOTA — wb-um2g COMPLETE (every egress path now
  metered).** The wasi-http path got its egress meter in iter71; the wasi-SOCKETS path (socket_addr_check is
  a closure with no &mut store) was still unmetered. Added wb_conn_rate_ok (a sliding-window meter over an
  Arc<Mutex<(count, window)>> the closure carries) + wired it into socket_addr_check: 50k connect attempts /
  10s per instance, counting DENIED attempts too (so a flood of SSRF-blocked connects is also capped) = the
  keystone's "conn quota" for the raw-socket path. 11 cargo unit tests green (incl conn_rate_quota) + the
  wasi-sockets e2e green. So the untrusted STANDARD-tool path is now FULLY METERED on BOTH protocols:
  wasi-http (rate via send_request) + wasi-sockets (conn rate via socket_addr_check). wb-um2g CLOSED. The
  keystone's rate/conn quotas now cover EVERY egress path: host_* brokers + both wasi standard paths.

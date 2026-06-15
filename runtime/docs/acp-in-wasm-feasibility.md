#+TITLE: ACP coding-harness in-WASM — Feasibility Report
#+EPIC: wb-b9xv (Track: harness-in-guest spike, the deferred half of the epic)
#+BRANCH: acp-spike-feasibility
#+WORKTREE: /Users/shinyobjectz/Apps/workbooks-acpspike
#+DATE: 2026-06-14
#+STATUS: GO-WITH-CAVEATS (headless slice) / NO-GO (interactive CLI, near-term)
#+PRODUCTION_STATUS: EXPERIMENTAL — v2, NOT production. The whole harness/ACP surface is gated behind
#+  Workbooks.Harness.experimental? (env WB_ACP_EXPERIMENTAL; defaults OFF in MIX_ENV=prod). It is RETAINED
#+  for development + reasoning, but does NOT ship to production and is NOT a published feature. Owner has
#+  major security reservations; a dedicated v2 security review is owed before any go-live. Do not present
#+  this as a shipping capability.

* TL;DR — VERDICT

*GO-WITH-CAVEATS.* Running a Node coding-harness (Claude Code class) as JS on
StarlingMonkey (`Workbooks.JsEngine`) is *feasible for a headless, programmatic
invocation* and the security shape (no native exec; tools = wasm CommandRegistry)
is correct and largely already built. It is *NOT* feasible as-shipped: the
harness bundle dies at module-load on line 1, the tool-spawn bridge is bound to
the wrong JS lane and is semantically wrong (buffered one-shot vs. live
streaming), and the interactive CLI needs a PTY the engine cannot provide.

The compute/web-platform half is *empirically proven done*. The Node
process/module model and live tool-spawning are the *real* gap, and the second
is genuinely hard (a new streaming process protocol + a persistent engine
instance). Recommend: build the smallest headless end-to-end slice first
(load-bootstrap → fs/process shims → one buffered tool call), defer streaming +
PTY, and ship subscription-auth brokering on *desktop only* first.

Per-claim evidence below is tagged *EMPIRICAL* (a probe actually ran on the live
engine / a file was read in this worktree) or *INFERRED* (reasoned, not run
here). Nothing is fabricated.

* 1. ENGINE REALITY — StarlingMonkey

Host module: =runtime/host/js_engine.ex= (=Workbooks.JsEngine=). Built eval-host:
=runtime/build/cache/jsengine/eval-host-023.wasm= — *EMPIRICAL*, file present, 11,113,021 bytes
(verified in this worktree). Built via componentize-js@0.18.5; each =eval/2= spins a fresh
instance (~0.64–0.77s cold), runs, tears down.

| Capability                                    | Verdict        | Evidence                                                            |
|-----------------------------------------------+----------------+---------------------------------------------------------------------|
| Arbitrary non-trivial eval (fib/spread/Map/Set) | EMPIRICAL-PASS | correct output, 643ms                                               |
| async/await + Promise (event loop settles)    | EMPIRICAL-PASS | awaited setTimeout resolved, Promise.all settled, 653ms             |
| WebCrypto: digest + importKey(raw)+sign+verify | EMPIRICAL-PASS | SHA-256 byte-identical to shasum; deterministic HMAC; verify=true   |
| WebCrypto: generateKey/export/encrypt/decrypt | EMPIRICAL-FAIL | surface enum: those 8 methods ABSENT; "generateKey is not a function" |
| fetch / wasi:http                             | EMPIRICAL-PASS | live GET httpbin 200 through WasiHttpView→NetGuard, 1136ms          |
| TextEncoder/Decoder, JSON, modern ES          | EMPIRICAL-PASS | UTF-8 round-trip, structuredClone, ?. / ??                          |

** =allow_http: true= is MANDATORY — *EMPIRICAL*
With =allow_http: false=, instantiation fails *before any JS runs*:
=component imports instance wasi:http/types@0.2.3, but a matching implementation was not found in the linker=.
StarlingMonkey hard-imports =wasi:http= regardless of whether the script touches the
network. Verified in source: =runtime/host/js_engine.ex= moduledoc (lines 14–20, 73) and the
instantiation =wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true}= (line 81). The same path
routes any guest =fetch()= through =WasiHttpView= → =NetGuard= (SSRF-safe brokered egress).
Consequence: you cannot run the engine with networking fully linked-out — fine for SSRF
posture, relevant for threat modeling.

** What's confirmed vs inferred
- *Confirmed (probe ran on the live engine):* eval, async event loop, WebCrypto subset,
  fetch egress, encoders/JSON/modern-ES, and the =allow_http= hard requirement.
- *Inferred (per moduledoc, not re-probed):* regex =\p{…}= unicode-property escapes fall
  back to QuickJS via =run_program/2=.

** Engine caveats material to a harness (honest)
- *Single-shot per eval.* =eval/2= spins a fresh instance and exits it after the call. No
  persistent JS heap/globals across calls; ~0.65s cold-start tax each call. A long-lived
  harness (holding child handles + state across turns) has no persistent instance to live in
  today. (*EMPIRICAL* lifecycle; the persistent-instance need is *INFERRED*.)
- *WebCrypto is a subset.* Hashing + HMAC-via-imported-raw-keys only. Auth signing works;
  in-engine asymmetric/symmetric keygen and envelope encryption do not — feed keys via
  =importKey= from host-supplied bytes instead.

* 2. THE NODE-COMPAT GAP

** Critical framing: TWO unrelated JS lanes — *EMPIRICAL (static)*
- *Javy/QuickJS lane:* =runtime/compilers/js/shims/*= + =runtime/host/js_dock.ex=. Every
  shim's brokered surface is reached through =Javy.IO= / =Javy.Exec= / =Javy.VFS= globals.
  This is the lane wired to the Dock + CommandRegistry/ExecBroker.
- *StarlingMonkey lane:* =runtime/host/js_engine.ex=. Verified: *0* references to =Javy= or
  =host_exec= in =js_engine.ex= (grep). SM exposes web-platform globals only. There is NO
  =process=, =require=, =Buffer=, =fs=, =child_process=, or CommonJS module system.

So the engine probe PASSes are real but cover the *easy half* (pure-compute + web platform).
The hard half (Node module graph + process model + tool-spawning) is unaddressed by SM, and
*the existing shims do NOT transfer* — they call =Javy.*= (absent in SM) and assume a QuickJS
CommonJS loader SM lacks. They must be *ported*, not reused.

** API classification for the StarlingMonkey target
- *Port (pure JS, no caps; mechanical):* events, path, util, querystring, url,
  string_decoder, assert, timers. stream — in-memory only, no real backpressure (weak, but
  portable).
- *Brokerable via Dock (seam exists in =js_dock.ex=, but SM has no import binding yet —
  net-new wiring, not reuse):*
  - =fs= → host VFS (KV-backed; dirs virtual, =mkdir= no-op, =readdir= []). *A real harness
    reads/writes a true working tree, lists dirs, stats, globs — the KV VFS is a poor fit.*
  - =process.env/argv/stdout/exit= → today's =process.js= hardcodes empty env,
    =argv=["node","script"]=, =exit= no-op, stdout via =Javy.IO=. SM has no Javy.IO; stdout
    must route to wasi stdout or a host import; env/argv host-injected.
  - =os= → constant stubs, fine. =crypto= → SM WebCrypto subset (see §1).
- *Hard wall:* =child_process.spawn/exec= (§ below), =readline/tty/PTY= (no shim exists —
  verified: no =readline.js=, no =tty.js=), real streaming/backpressure (in-memory stub only),
  raw =net/dgram/tls= sockets (brokered in Dock but unbound in SM; rarely needed vs fetch).

** Ranked first walls
1. *Module/process bootstrap (load-time).* The bundle won't instantiate on SM until a =node:=
   builtin resolver + =process=/=Buffer=/=require= globals exist and the pure-JS shims are
   ported off =Javy.*= onto SM host imports. Unavoidable first step. Effort: *MEDIUM* (porting
   is mechanical; the componentize-js loader/global injection is the real work).
2. =child_process.spawn= as a *streaming, long-lived* process model. The buffered one-shot
   bridge is the right *security* shape but (a) is unbound in the SM world and (b) cannot
   represent live children with stdin/stdout/stderr/exit/signals. Needs a new multiplexed
   process protocol over the Dock + a persistent SM instance. Effort: *HIGH* — make-or-break.
3. =readline/tty/PTY= + true streaming I/O. No shim, no TTY in a request/response component.
   Deferrable for headless; a wall for the interactive CLI. Effort: *HIGH*, partly a
   capability wall.

** The child_process → CommandRegistry bridge difficulty
The bridge *already exists end-to-end in the Javy lane* and is the correct design (*EMPIRICAL
static*, files verified):
=child_process.spawn= → =Javy.Exec.run= → =host_exec= import (=js_dock.ex:142=) →
=ExecBroker.exec= (=runtime/host/exec_broker.ex=: =@max_depth 8= line 20, =@default_max_output
8*1024*1024= = 8 MiB line 19, default-deny, registered-only, no shell parse, per-principal
concurrency cap) → =CommandRegistry.run= (the ~91 wasm CLIs). Zero native exec.

Against StarlingMonkey it is a *HARD WALL* for *structural*, not security, reasons:
1. No =Javy.Exec= in SM and no =host_exec=-analogous import wired into the componentize-js
   world (it hard-imports only =wasi:http=, *confirmed mandatory*). You'd add an exec import to
   the SM component world + surface it as a JS global.
2. *Semantic mismatch (fatal for a harness):* the existing bridge is SYNCHRONOUS, ONE-SHOT,
   BUFFERED. =child_process.js= confirms it: it dispatches via =Javy.Exec.run(...)= returning
   full stdout at once; =spawn().stdout= emits one =data= then =end= (verified in
   =runtime/compilers/js/shims/child_process.js=). A harness needs long-lived children with
   streaming stdout/stderr, writable stdin, exit codes, signals, concurrency. The Dock's
   request/response, 8-MiB-capped primitive cannot model a live process. *Bridging spawn is
   not "wire one import" — it's inventing a streaming, multiplexed process protocol over the
   Dock that does not exist today.*
3. SM lifecycle: fresh instance per =eval=, no persistent heap to hold child handles/state.

* 3. HARNESS-LOAD PROBE RESULT — *EMPIRICAL*

What ran (not inferred): an ~80-line coding-harness-shaped Node probe
(=require('node:child_process'/'node:fs')=, =process.argv/env=, async LLM =fetch= loop,
=cp.spawn('echo',…)= streaming a tool, =fs.writeFileSync= + =process.stdout.write=) on the
LIVE =Workbooks.JsEngine= via =mix run --no-start=. Engine confirmed runnable
(=eval("6*7") -> {:ok,"42"}=).

*FIRST WALL (proved):* =JsEngine.eval(probe)= → ="ERR: require is not defined"=. SM throws on
line 1 of the bundle (the first =require=) before any harness logic runs. =run_program= then
auto-fell to the QuickJS lane, which couldn't build in this checkout
(=clang_not_built= — compilers not provisioned). So the bundle never loads on SM and the
fallback can't compile it either (reported verbatim; the fallback was not exercised to
completion *only* because clang isn't provisioned here).

Bootstrap surface walked global-by-global on raw SM (each a real eval):
- *ABSENT (load-time blockers):* =require=, =module=, =process=, =Buffer=, =global= — all
  undefined. Any Node bundle dies before executing.
- *PRESENT (web-platform half):* =globalThis=, =fetch=, =setTimeout=, =TextEncoder=, =crypto=,
  =crypto.subtle=, =crypto.subtle.digest=, =structuredClone=, =URL=, =queueMicrotask=.
- crypto gap re-confirmed: =digest= present, =generateKey= undefined.
- Exec bridge absent in SM: =typeof Javy === "undefined"=; =js_engine.ex= has 0 =host_exec=/=Javy=
  refs (re-verified). The bridge is real but unbound to SM.

** Real-Claude-Code-specific blockers — *INFERRED, labeled (not run here)*
- *Distribution:* npm =@anthropic-ai/claude-code=, a bundled CLI (=claude= bin); a large single
  bundled JS entrypoint (order ~5–10 MB minified). Self-updating; shells out to native-ish
  deps (e.g. ripgrep).
- *Top blockers to loading IT on SM, in order:*
  1. Load-time bootstrap (the wall the probe HIT): its bundle =require=s/imports
     =node:fs/child_process/process/os/readline/tty= and reads =process.argv/env= at module
     eval — throws on SM before line 1. Inject =process/Buffer/require= + a =node:= resolver +
     port shims off =Javy.*=. (MEDIUM.)
  2. Tool-spawning as live streaming children (ripgrep/git/node/LSPs) → the ~91 wasm CLIs, but
     needs the multiplexed streaming process protocol + persistent instance. (HIGH — make-or-break.)
  3. Interactive terminal (REPL/raw-mode/keypress/resize/ANSI) needs a PTY; SM has none.
     Deferrable headless; a wall interactive. (HIGH, partly capability.)
- *Parsing of modern ES is NOT the problem* — the probe confirmed optional chaining/spread/
  structuredClone parse fine. The failure is module resolution + missing process/Buffer
  globals.

* 4. SUBSCRIPTION-OAUTH DOCK-BROKERING DESIGN (wb-b9xv.7, Track B)

** The model we must not break — *INFERRED (provider behavior) + EMPIRICAL (reuse files)*
Claude Code → Claude Pro/Max and Codex → ChatGPT Plus/Pro both use OAuth 2.0 *Authorization
Code + PKCE* (NOT an API key): the harness makes a PKCE verifier/challenge, opens the system
browser to consent, captures a loopback (=http://localhost:<port>/callback=) or paste-back
code, exchanges code → ={access,refresh,expires}=, persists in its OWN store
(=~/.claude/.credentials.json= / OS keychain; Codex =~/.codex/auth.json=), and silently
refreshes. =ANTHROPIC_API_KEY= / =OPENAI_API_KEY= are the *separate, mutually-exclusive*
credits path.

*Load-bearing ToS constraint:* the subscription token is per-user, BYO, *never pooled, never
proxied through our servers, never stored by us*. The credential stays in the user's trust
domain; egress is direct user→provider.

*Key fact:* the harness already owns its full auth state machine. We do NOT reimplement OAuth.
We give an in-wasm harness three host-brokered primitives it would otherwise get from native
syscalls.

** The ACP trigger — *INFERRED (ACP semantics; note: =runtime/docs/acp.md= is NOT present in
this checkout — it is wb-b9xv.1, still OPEN)*
After =initialize=, non-empty =authMethods= ⇒ "not authenticated, drive =authenticate= before
=session/new=". Empty ⇒ creds already valid. Treat non-empty as "drive the harness's OWN
login," never assume which OAuth.

** Three Dock imports (mirror RustDock/JsDock intent-in/host-performs)
- (a) =dock.creds.{get,put}= — credential store. The Node shim maps the harness's store
  read/write to these instead of a wasm FS. Backed by the *user's OS keychain* via the desktop
  =keyring::Entry= pattern (verified =desktop/src-tauri/src/keychain.rs:563 connections_create=,
  =:594 connections_reveal_api_key=; and =KC_WORKOS_SESSION= in =network.rs:227/236=) under a new
  service =sh.workbooks.harness.<provider>=, scoped per-(user, provider). We store an opaque
  blob on the user's machine; we never read it or send it anywhere except (c).
- (b) =dock.oauth.loopback= — browser-open + loopback callback. Generalizes =workos_sign_in=
  (verified =network.rs:182=; =tiny_http::Server::http("127.0.0.1:0")= line 183; =open::that=
  line 197; =pkce()= line 167). Host binds =127.0.0.1:0=, substitutes the real
  =redirect_uri=, opens the browser, blocks for the one redirect, returns ={code,redirect_uri}=.
  *Move PKCE generation OUT* — the harness does S256 in WebCrypto so the verifier never crosses
  the membrane.
- (c) Egress — *existing* =fetch()= → =NetGuard= (verified surface =net_guard.ex:85 request=,
  =:324 dest_allowed?=, =:353 allowed?=, =:392 pin_allow_list=) with a per-host =:allowlist=
  grant. Direct user→provider; bearer attached by the harness, lives only in the request. No
  new primitive.

** Flow (Track B), end to end
=JsEngine.run= with grant ={net: :allowlist, net_allow:["api.anthropic.com:443"], creds_scope:{user,"claude"}}=:
read store via =dock.creds.get= → ACP =initialize= → non-empty =authMethods= ⇒ PKCE (WebCrypto)
→ =dock.oauth.loopback= → host browser+socket → ={code}= → harness =fetch= token endpoint →
=dock.creds.put= → =authenticate= ok → =session/new=/=prompt= (bearer'd =fetch=→NetGuard). Later
runs: =creds.get= returns bundle, harness refreshes silently, no browser.

** Reuse points (file-level — all verified present)
- Loopback+PKCE browser flow: =desktop/src-tauri/src/network.rs= (=workos_sign_in= 182, =pkce=
  167, tiny_http 183, open::that 197) → becomes =dock.oauth.loopback= (PKCE moved out).
- Keychain store: =desktop/src-tauri/src/keychain.rs= (=connections_create/reveal= 563/594) +
  =KC_WORKOS_SESSION= get/set in =network.rs= (227/236) → backs =dock.creds.{get,put}=.
- Brokered egress: =runtime/host/net_guard.ex= (=request/dest_allowed?/allowed?/pin_allow_list=).
- Harness runtime + crypto + async: =runtime/host/js_engine.ex= (=run_program/2=, =eval/2=,
  =allow_http: true= WasiHttpView→NetGuard).
- Dock membrane to mirror: =runtime/host/rust_dock.ex= / =runtime/host/js_dock.ex= (=harness_dock.c=).
- API-key fallback only (NOT subscription): =runtime/host/secret_broker.ex= (=register= 19,
  =sign= 30). Subscription tokens are never registered as our secrets.

** Open risks (auth)
1. *ToS proximity (highest).* Brokered ops must be provably per-user, non-pooling: =creds_scope=
   hard-bound to the WorkOS user; egress not through a shared control-plane proxy. A multi-tenant
   cloud nexus with a shared egress IP/machine across users' subscription tokens is exactly the
   "pooled/proxied" pattern the providers forbid. ToS-clean only if each user's harness runs in
   *their own* tenant with *their own* keychain store + non-re-attributable egress. *Needs legal/ToS
   read before any cloud deployment.* Desktop (user's machine/keychain/browser/IP) is unambiguously
   their trust domain — ship there first.
2. *Browser-open in a headless cloud nexus.* =loopback= assumes a local browser + reachable
   localhost. Remote nexus needs a *device-code / paste-back* fork; the loopback socket must bind
   on the user's side. Forks the design: loopback (desktop) vs device-code (remote).
3. *Token refresh while idle.* Refresh =fetch= stays in-harness; host only keeps the allowlist open.
4. *Node-compat shim fidelity for the store path* — if the harness uses an unexpected store path or
   a native keychain binding we don't shim, it silently re-login-loops. First wall to probe.
5. *=authMethods= semantics drift* across harnesses — don't assume a fixed shape.
6. *macOS keychain prompt friction* — per-provider service names reduce repeat prompts.

* 5. THE REAL GAP + EFFORT + BUILD SEQUENCE

** The real gap (one sentence)
The engine clears the compute/web-platform half (proven); the gap is *the Node process/module
bootstrap* (port shims off =Javy.*= + inject =process/Buffer/require= + a =node:= resolver) and
*live tool-spawning* (a streaming, multiplexed process protocol over the Dock + a persistent
SM instance) — the existing host_exec→ExecBroker→CommandRegistry bridge is the right security
foundation but is bound to the wrong lane and is buffered one-shot.

** Rough effort estimate (engineering, not calendar)
| Slice                                                            | Effort |
|------------------------------------------------------------------+--------|
| Load-bootstrap (node: resolver + process/Buffer/require globals) | MEDIUM |
| Port pure-JS shims off Javy.* (events/path/util/fs/process/os…)  | MEDIUM |
| Bind host_exec (buffered, one-shot) into the SM world            | MEDIUM |
| Persistent SM instance (heap + handles across turns)             | HIGH   |
| Streaming/multiplexed child_process protocol over the Dock       | HIGH   |
| readline/tty/PTY (interactive)                                   | HIGH/capability wall |
| Subscription-auth brokering, DESKTOP (3 Dock ops, mostly reuse)  | MEDIUM |
Aggregate to a *headless end-to-end* harness: roughly MEDIUM-HIGH. Aggregate to the *full
interactive CLI*: HIGH and partly gated on a capability (PTY) the request/response component
does not have. (*INFERRED* sizing.)

** Recommended build sequence (smallest first slice that proves the path end-to-end)
1. *SLICE 0 — load-bootstrap proof.* [DONE — PROVEN LIVE 2026-06-14, wb-b9xv.8]
   Make a *trivial* Node-shaped script (just =require('node:path')= + =process.argv= + a
   =fetch=) instantiate and run on SM. Proves the =node:= resolver + global injection + first
   ported shims. This alone clears the wall the probe hit. (No tools, no streaming yet.)
   Landed as =Workbooks.JsEngine.run_node/2= + =runtime/compilers/js/node-prelude.js=, evaluated
   in the source layer (no wasm-host rebuild). Resolves =path/events/util/os/querystring/url/
   string_decoder/assert/timers= (bare, =node:=, and =./relative= between shims) + host-injected
   =process= (env/argv) + =Buffer=. =require('node:fs')= / =child_process= correctly throw
   "Cannot find module" (SLICE 1). Sync half fully correct through =run_node=; async =fetch=
   output capture deferred (proven via =eval/2= which awaits — see HONEST LIMITATION in handoff).
2. *SLICE 1 — one buffered tool call.* Bind =host_exec= into the SM world, route a single
   =child_process.execFileSync('rg', …)= to CommandRegistry, get buffered stdout back. Proves
   the security spine (default-deny, registered-only, sandbox-invariant green) on the SM lane.
3. *SLICE 2 — headless harness turn.* Persistent SM instance + ported fs/process; drive ONE
   non-interactive harness turn (prompt in → buffered tool calls → answer out). This is the
   first *end-to-end* proof that the path works for a real harness, headless.
4. *SLICE 3 — desktop subscription auth.* The three Dock ops (creds.get/put, oauth.loopback,
   fetch→NetGuard), desktop-only, behind the new =agent= cap. Mostly reuse.
5. *DEFER:* streaming/multiplexed process protocol (only when a tool needs live output), PTY/
   interactive CLI, cloud-nexus device-code auth.

Slices 0–2 are the critical path and each is independently verifiable; if SLICE 2 lands, the
"harness-in-guest" thesis is proven for headless use.

* 6. HONEST RISKS / UNKNOWNS
- *Persistent SM instance is unbuilt and unprobed.* =eval/2= is single-shot today; a long-lived
  pooled instance is *INFERRED* to be needed and its cost/feasibility is not measured here.
- *Streaming process protocol is a net-new invention*, not a wiring task — the largest
  uncertainty. Could prove harder than MEDIUM-HIGH if backpressure/signals are needed.
- *The QuickJS fallback path was not exercised to completion* (clang not provisioned in this
  checkout) — so the fallback's behavior on a Node bundle is unverified here.
- *Real Claude Code bundle was not loaded* — its specific blockers are *INFERRED* from the
  generic probe + known distribution shape, not from instantiating the actual ~5–10 MB bundle.
  Bundle size + self-update behavior could surface surprises.
- *=runtime/docs/acp.md= (wb-b9xv.1) does not yet exist in this checkout* — the ACP wire/grant
  references in §4 are against the epic's intended contract, not a written doc.
- *ToS clearance for any cloud deployment is unresolved* — desktop-first is the only
  unambiguously safe path.
- *WebCrypto subset* — if a harness or its SDK needs in-engine asymmetric keygen/encrypt, it
  fails; mitigation (importKey from host bytes) assumes the harness can be steered to it.
- *fs KV-VFS mismatch* — a real working tree (dirs/stat/glob/large files) is a poor fit for the
  KV VFS; how much of a harness's fs usage this breaks is unmeasured.

* MAINTAINER SUMMARY
StarlingMonkey is genuinely strong for the *compute + web-platform* half a harness needs —
eval, async event loop, fetch (SSRF-brokered through NetGuard), and enough WebCrypto for
PKCE/HMAC auth are all *empirically proven* on the live engine. =allow_http: true= is a hard
requirement (the engine won't even instantiate without it). But a Node coding harness is gated
on three things SM does not provide: (1) the Node module/process bootstrap (the harness dies on
its first =require= — proven), (2) live tool-spawning as streaming children (the existing
host_exec→ExecBroker→CommandRegistry bridge is the right security shape and is already built,
but it lives in the *Javy/QuickJS* lane, is unbound to SM, and is buffered one-shot — wrong for
a harness), and (3) a PTY for the interactive CLI (no TTY in a request/response component).
Wall 1 is MEDIUM and mechanical; wall 2 is HIGH and is the make-or-break invention; wall 3 is
deferrable for headless. Subscription auth is *mostly reuse* (generalize =workos_sign_in= +
=keyring::Entry= + NetGuard into three Dock ops) and should ship *desktop-only first* for ToS
safety. Recommend GO on a headless slice (Slices 0→2 prove the path end-to-end), NO-GO on the
interactive CLI near-term, and a ToS read before any cloud deployment of brokered subscription
auth.

* BD SUB-ISSUES TO FILE UNDER wb-b9xv
(Track-B harness-in-guest spike; complements existing .1–.7. Suggested ids continue the series.)
- *wb-b9xv.8 — SM node-bootstrap layer:* [DONE 2026-06-14] =node:= builtin resolver + inject
  =process/Buffer/require/global= globals into the componentize-js world; SLICE 0 proof
  (=require('node:path')= + =process.argv= + =fetch= runs on SM). [P1, MEDIUM] — landed in
  =Workbooks.JsEngine.run_node/2= + =node-prelude.js=; verified =mix test
  test/js_node_bootstrap_test.exs --include build --include netdeps= → 4 tests, 0 failures.
- *wb-b9xv.9 — Port pure-JS shims off =Javy.*= to SM host imports:* events/path/util/
  querystring/url/string_decoder/assert/timers/stream/os, plus fs (host VFS) and process
  (env/argv/stdout/exit) rebound to SM imports, not =Javy.IO/VFS=. [P1, MEDIUM]
- *wb-b9xv.10 — Bind =host_exec= into the SM component world + buffered tool call:* SLICE 1 —
  route =execFileSync('rg', …)= → ExecBroker → CommandRegistry on the SM lane;
  sandbox_invariant_test stays green. [P1, MEDIUM]
- *wb-b9xv.11 — Persistent SM instance (pooled, heap + handles across turns):* lift the
  single-shot =eval/2= lifecycle so a harness can hold state across many turns. [P1, HIGH]
- *wb-b9xv.12 — Streaming/multiplexed child_process protocol over the Dock:* live
  stdout/stderr/stdin/exit/signals/concurrency for long-lived children; the make-or-break
  invention. [P1, HIGH]
- *wb-b9xv.13 — Headless end-to-end harness turn (SLICE 2 capstone):* one non-interactive
  prompt→tool-calls→answer on the SM lane; the thesis proof. [P1, HIGH] (depends .8–.11)
- *wb-b9xv.14 — readline/tty/PTY for interactive CLI (DEFERRED/capability spike):* assess
  whether a PTY can exist beside a request/response component or needs a different tier. [P2, HIGH]
- *wb-b9xv.15 — =dock.oauth.loopback= (generalize =workos_sign_in=, PKCE moved into harness):*
  desktop Dock op; verifier never crosses the membrane. [P1, MEDIUM] (Track B / extends .7)
- *wb-b9xv.16 — =dock.creds.{get,put}= keychain-backed store (=sh.workbooks.harness.<provider>=,
  per-(user,provider) scope):* desktop; the harness's own store mapped to keychain. [P1, MEDIUM]
- *wb-b9xv.17 — Cloud device-code auth fork + ToS clearance gate:* device-code/paste-back
  variant for headless nexus; blocked on per-user-isolation ToS read. [P2, MEDIUM] (DEFERRED)
- *wb-b9xv.18 — fs working-tree fidelity over KV VFS:* assess/mitigate dir/stat/glob/large-file
  gaps a real harness assumes. [P2, MEDIUM]

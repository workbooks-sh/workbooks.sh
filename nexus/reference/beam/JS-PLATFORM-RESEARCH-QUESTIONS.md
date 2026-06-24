# A dense, NIF-free JavaScript platform on the BEAM — research brief #3 (the Node-API shim, ergonomics, performance, and the strategic wedge)

**Purpose.** We've built and *proven* a JavaScript-on-the-BEAM substrate that earlier feasibility reports
endorsed — but ours differs from the recommended path in one decisive way: **no NIF.** We run QuickJS
compiled to WebAssembly inside our pure-Elixir wasm runtime ("Washy"), one guest per BEAM process. This
brief asks the *next* layer of questions — now that "does it work" is answered — about what it takes to
run the real JS ecosystem on it, how fast it can be, and where it actually wins. Please answer directly,
cite specifics, and challenge our assumptions.

---

## 1. What we've built (and proven end-to-end)
- **Execution:** untrusted JS runs as QuickJS-compiled-to-wasm inside Washy (an in-process wasm
  interpreter + a wasm→BEAM-assembly JIT). One guest = one BEAM process. Fuel-bounded (preemptible),
  crash-isolated, dense (target: thousands of guests/box vs dozens of containers). **No NIF, no OS thread
  per engine** — unlike QuickBEAM (which embeds QuickJS-NG as a Rustler NIF on a dedicated OS thread).
- **npm (pure JS):** real packages bundle (real esbuild, run as wasm under wasmtime) and run; a real
  transitive dependency graph executes bit-identically to the reference interpreter.
- **`Beam.*` interop (DONE, e2e):** a JS guest is a first-class BEAM citizen — `Beam.call(name, …)` into
  Elixir, `Beam.self()`, `Beam.spawn(script)`, `Beam.send(pid, msg)`, `Beam.onMessage(cb)` — each a JS
  global backed by a wasm host import → a `call_host` seam → a supervised `GenServer`-per-guest actor.
  JS→Elixir, actor identity, and Elixir→JS delivery into `onMessage` all verified. Messages cross the
  boundary as a JSON-structural Erlang-term mapping.
- **Density:** the atom-table wall is *closed* (module-name atoms bounded to a fixed recycled pool,
  forever); the JIT code cache is ETS (no global-GC scan storm); live density telemetry exists.
- **Known limits today:** JS is interpreter-speed (the JIT helps, but ~33% of QuickJS functions are
  native so far; the prior report concluded native-JS speed needs a NIF, which we reject on isolation/
  density grounds). Guest QuickJS state currently resets per actor-message (persistence is in progress).
  Native npm addons (N-API) are out of scope (confirmed infeasible without a NIF).

---

## 2. The questions

### A. The Node-API shim layer (the frontier for "runs the ecosystem")
Pure-JS packages already run. The next unlock is packages that expect Node core modules. We can map them
to OTP primitives instead of libuv.
1. **Priority + minimal viable surface.** Which Node core modules, in what order, unlock the *largest*
   fraction of real npm packages with the *least* work? Rank: `buffer`, `events`, `stream`, `util`,
   `path`, `process`, `timers`, `fs`, `net`, `http`/`https`, `crypto`, `url`, `os`, `child_process`,
   `worker_threads`. What's the 80/20 — the smallest set that makes "most pure-JS-plus-stdlib" packages
   work?
2. **OTP mappings — confirm or correct ours:** `timers` → the BEAM timer wheel (`erlang:start_timer`);
   `fs` → `:file` (async driver thread pool); `net`/`http` → `:gen_tcp`/`:socket` + the OTP I/O poll
   thread (epoll/kqueue), delivering to the guest's mailbox; `process`/`os` → host shims; `buffer` →
   guest-side typed arrays; `path`/`url`/`util` → pure-JS polyfills; `crypto` → host BIFs (`:crypto`)
   exposed as host imports. Where is this wrong or naive? What's hard (streams + backpressure across the
   wasm boundary; `http` keep-alive; DNS)?
3. **The event-loop reconciliation.** Node is single-threaded run-to-completion on a libuv loop; our guest
   is a BEAM process delivered messages run-to-completion. How do we present a faithful-enough event loop
   (`setTimeout`, microtasks/promises, `process.nextTick`, async I/O completion) on top of the actor
   mailbox? QuickJS has a job queue (`JS_ExecutePendingJob`) — how should host async I/O (a `:gen_tcp`
   reply landing in the mailbox) re-enter the guest and resolve the right promise?
4. **`child_process` / `worker_threads`.** Should these map to `Beam.spawn` (a new guest actor) — i.e.
   "a worker is just another supervised JS process"? What breaks vs Node's shared-memory `worker_threads`?

### B. Interop ergonomics (beyond JSON-structural)
5. Our JS⇄Erlang term bridge is currently a JSON-equivalent structural mapping (number/string/bool/nil/
   list/map). What richer shapes earn their keep — **binaries** (zero-copy across the boundary?),
   **streams** (lazy/backpressured), **references to host resources** (a file handle, a socket, a PID as
   an opaque handle)? Where's the line before this becomes a distributed-objects tarpit?
6. **Backpressure + flow control:** a JS guest reading a large stream (HTTP body, file) from a host that's
   a `:gen_tcp` socket — how do we propagate backpressure into single-threaded QuickJS without a real
   event loop blocking the BEAM process unboundedly? (We have fuel + per-call timeouts; is that enough?)

### C. Performance envelope (where is "fast enough" actually enough?)
7. **The realistic numbers.** For representative server workloads — an HTTP request handler, JSON
   parse/transform, template/SSR rendering, a crypto/hash loop — what throughput/latency should we expect
   from **QuickJS-interpreted-in-wasm-in-BEAM** + our partial wasm→native JIT, vs (a) native QuickJS-NIF
   (QuickBEAM), (b) Node/V8? Order-of-magnitude is fine. Where does our model land — 2×? 10×? 50× slower
   than V8 — and for which workload classes does that matter vs not?
8. **The JIT ceiling.** Our wasm→BEAM-assembly JIT runs QuickJS-the-engine faster, but with fuel charged
   per loop iteration the runtime converges toward the interpreter for hot loops (the per-iteration host
   call dominates). Is there a smarter fuel/preemption scheme (reduction-aware, amortized) that keeps
   preemption safety without paying a call per iteration? Could we ever AOT a *specific* hot JS function
   to BEAM (Porffor-style JS→wasm→BEAM) rather than interpreting it in QuickJS — and is that worth it?
9. **Density vs speed tradeoff curve.** At what guest count does the per-guest memory floor (process heap
   + the QuickJS wasm linear memory) dominate, and what's the realistic guests-per-GB for idle vs active
   JS guests? (We measured ~8–12 KiB/idle BEAM process before the JS heap; QuickJS adds 10–64 KiB.)

### D. The strategic wedge (where this uniquely wins)
10. QuickBEAM (NIF) gets native JS speed but is OS-thread-bound (dozens of runtimes) and a crash takes the
    node. We get density (thousands) + perfect isolation + preemption, at interpreter-ish speed. **For
    which workloads is our tradeoff the *right* one, decisively?** Our thesis: **many small, supervised,
    per-tenant JS units** — edge/middleware handlers, per-customer business logic, agent/tool sandboxes,
    untrusted user scripts — where you want 10,000 cheap isolated JS functions, not one fast monolith.
    Pressure-test this: where is it wrong? What's the workload where we'd lose to QuickBEAM or to just
    running Node?
11. **The "JS as supervised actor" programming model** — is there real value in JS that can `spawn`/
    `send`/`link`/be-supervised like an Erlang process (vs JS that's just sandboxed)? What application
    patterns does that unlock that neither Node nor a plain JS sandbox can express well?
12. **AOT JS→wasm (Porffor/StarlingMonkey) as a future lane.** Compiling JS *itself* to wasm (then wasm→
    BEAM via our JIT) instead of interpreting via QuickJS — would that close the speed gap for the hot
    path while keeping our isolation model? What does it cost (completeness, dynamic features, closures)?

### E. Persistent guest state + lifecycle
13. We're making each JS guest's QuickJS instance persist across messages (keep the wasm linear memory +
    JSContext alive in the owning GenServer, re-enter a dispatch export per message). Risks at scale: the
    per-guest linear memory now lives for the guest's lifetime (density cost); a long-lived guest's
    QuickJS heap fragments/grows. How should we bound/GC a long-lived guest (QuickJS `JS_RunGC`, memory
    limits, idle eviction → re-hydrate from the script)? Snapshot/restore of a QuickJS heap?

### F. What a great answer looks like
A prioritized **Node-core-module shim roadmap** (the 80/20 set + the OTP mapping for each, hardest-first
flagged), a concrete **event-loop-on-actor-mailbox** design (timers + promises + async I/O re-entry), an
honest **performance envelope** (our model vs QuickBEAM vs Node, per workload class, with the "fast enough"
verdict), and a sharp judgment on **the wedge** — the workloads where dense, supervised, NIF-free JS is
the decisively right answer, and where it isn't. Correct our mental model where it's wrong.

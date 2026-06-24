# JS ↔ OTP Interop — the `Beam.*` surface (design)

**Status:** host-side mechanism prototyped + tested (`lib/washy/actor.ex`, `lib/washy/actor/term.ex`,
`test/washy_actor_test.exs`). JS wiring (`Beam` global in `harness_run.c`) designed below; awaits a
`qjs-run.wasm` rebuild on the provisioned compiler toolchain.

## North star
QuickJS-compiled-to-wasm runs one guest per BEAM process inside Washy — NIF-free, isolated, dense. The
missing piece that turns the *sandbox* into a *platform* is OTP interop: a guest can spawn other guests,
send/receive messages, call Elixir, and be supervised — the `Beam.*` API (modeled on QuickBEAM, but with
**no NIF**; the isolation IS the BEAM process).

## The core problem: one-shot run → persistent actor
Today `Nexus.Washy.call_io/4` runs a guest to completion in a one-shot `Task` (`Sandbox.run_command`).
The actor model needs a **persistent guest actor**: a process that runs, yields, and is **resumed when a
message arrives** — run-to-completion per message, exactly like a `GenServer`.

### Solution: a GenServer per guest
`Nexus.Washy.Actor` is a `GenServer` under a `DynamicSupervisor`, holding the guest's durable state
between messages:

```
DynamicSupervisor (Nexus.Washy.Actor.Supervisor, :one_for_one)
 ├─ Actor GenServer  (guest A — script + QuickJS module state + onMessage cb id)
 ├─ Actor GenServer  (guest B …)            mailbox = the BEAM process mailbox
 └─ …
Registry (Nexus.Washy.Actor.Registry, :unique)   name → pid   (Beam.send "name", Beam.call "name")
```

- **Mailbox** = the BEAM process mailbox. `Beam.send(pid, m)` → `GenServer.cast(pid, {:beam_msg, m, from})`.
- **Resume-on-message** = `handle_cast` / `handle_call`. Each delivery runs the guest **run-to-completion
  for that one message**, then the process blocks in `receive` (GenServer loop) — a natural yield.
- **Durable JS state** lives in the GenServer state. In the prototype the `:fun` backend holds Elixir
  state; the `:js` backend will hold the QuickJS module image / a handle the harness re-enters.
- **Crash isolation** is free: a guest crash kills only its process; the supervisor + siblings survive
  (proven by the crash-isolation test). Restart policy is per-actor (`:temporary` default).

## `Beam.*` API → BEAM primitives

| JS call                 | Host primitive (`Nexus.Washy.Actor`) | BEAM mapping |
|-------------------------|--------------------------------------|--------------|
| `Beam.self()`           | `beam_self/0`                        | actor pid (process-dict `:washy_actor_self`) |
| `Beam.spawn(script)`    | `beam_spawn/2`                       | `DynamicSupervisor.start_child` → Actor GenServer |
| `Beam.send(pid, msg)`   | `beam_send/2`                        | `GenServer.cast` → mailbox |
| `Beam.onMessage(cb)`    | host import `beam_on_message`        | stash JS callback id in actor state; re-entered per msg |
| `Beam.call(name, …a)`   | `beam_call/3`                        | `GenServer.call` (sync, timeout-bounded) |
| `Beam.processInfo()`    | `process_info/1`                     | `Process.info` (reductions/memory/mailbox) |
| `Beam.systemInfo()`     | `system_info/0`                      | `:erlang.system_info` (proc/atom count, run queue) |

`beam_self` uses the process dict (`:washy_actor_self`), set around every delivery — mirroring `call_io`'s
process-dict discipline so a nested `Beam.spawn`/`send`/`call` inside a handler resolves correctly.

## Message serialization: JS ⇄ Erlang term
`Nexus.Washy.Actor.Term` defines the shared wire shape — JSON-equivalent but kept as **terms**, not text:

```
nil | boolean | number(int|float) | binary(string) | [term] | %{binary => term}
```

`normalize/1` projects any Elixir term into this shape (atoms→strings, tuples→lists, map keys→strings)
and is **idempotent**, so a round-trip is bit-stable for any in-shape value. The QuickJS side produces the
same shape: `number⇄number`, `string⇄string`, `Array⇄list`, plain `Object⇄string-keyed map`. Integers
stay exact (no float coercion). `to_json`/`from_json` give a JSON-text alt for a debug or cross-host hop;
the in-VM path stays as terms (no parse/encode per message). An un-bridgeable term (pid/ref/fun) raises
loudly rather than leaking an opaque handle into a guest.

## The `harness_run.c` changes (needs a qjs-run.wasm rebuild)

Inject a `Beam` global beside `Javy`/`console`, whose methods call **new host imports**. The harness is
synchronous QuickJS, so `Beam.send`/`spawn`/`call` are blocking C functions calling host imports (same
pattern as `wb_read`/`wb_write` → `Javy.IO`). Sketch:

```c
/* host imports (added to the import object Washy fulfills in call_host):
 *   beam_self(buf_ptr) -> len            // write self handle (string) into buf, return its length
 *   beam_spawn(src_ptr, src_len) -> handle_id   // returns an int handle id (mapped host-side → pid)
 *   beam_send(to_ptr, to_len, msg_ptr, msg_len) -> 0   // msg is JSON bytes (TextEncoder)
 *   beam_call(name_ptr, name_len, args_ptr, args_len, out_ptr) -> out_len  // sync; writes reply JSON
 *   beam_recv(out_ptr) -> out_len        // pull the message the host placed for this re-entry (JSON)
 */
static JSValue beam_send_js(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  const char *to = JS_ToCString(ctx, argv[0]);
  /* JSON.stringify(argv[1]) via a cached stringifier, then host_beam_send(to, json) */
  ...
  return JS_UNDEFINED;
}
/* Beam.onMessage(cb): store cb in a module global; the host re-enters by calling
 * __beam_dispatch(JSON.parse(beam_recv())) which invokes the stored cb. */
static const char *BEAM_PRELUDE =
  "globalThis.Beam={__cb:null,"
  "  self(){return __beam_self();},"
  "  spawn(s){return __beam_spawn(String(s));},"
  "  send(p,m){return __beam_send(String(p),JSON.stringify(m));},"
  "  call(n,...a){return JSON.parse(__beam_call(String(n),JSON.stringify(a)));},"
  "  onMessage(cb){this.__cb=cb;},"
  "  processInfo(){return JSON.parse(__beam_pinfo());},"
  "  systemInfo(){return JSON.parse(__beam_sinfo());}};"
  "globalThis.__beam_dispatch=function(m){if(Beam.__cb)Beam.__cb(m);};";
```

The matching `call_host` clauses go in `lib/washy.ex` (the host-import seam) and dispatch to
`Nexus.Washy.Actor.beam_*`, reading/writing guest memory with the existing `read_bytes`/`write_bytes`
helpers. They are **pure additions** — no change to existing imports.

### Re-entering JS per message (the resume step)
On `handle_cast({:beam_msg, msg, from}, state)` the `:js` backend will:
1. Place `msg` (JSON) where `beam_recv` reads it (process dict, like `:washy_exec_out`).
2. Run the guest module's `__beam_dispatch` entry via the Washy seam, with `:washy_actor_self` set, so
   inside the callback `Beam.self/send/spawn/call` resolve. This is the documented one line:
   `Sandbox.run_command({:interp, qjs_run_wasm, script}, "")` re-entered against the persisted module
   image. Run-to-completion = the call returns; then the GenServer blocks for the next message.

The prototype proves steps' host side end-to-end; only the in-guest callback dispatch awaits the wasm
rebuild.

## What's NOT changed
No edits to `transpile.ex`, `jit_cache.ex`, `metrics.ex`, `module_pool.ex`, `application.ex` (parent wires
the supervision child — see below). `Beam.*` is a new, additive seam.

# Persistent Guest Instances — keeping a JS guest's QuickJS heap alive across messages

## Problem

A guest runs one-shot today: `Nexus.Washy.call_io(mod, "_start", …)` instantiates the wasm, runs to
completion, tears the run context down. The `:js` actor backend (`lib/washy/actor.ex`) therefore re-runs
the ENTIRE script on every delivered message — so any JS state (`let count = 0`, closures registered by
`Beam.onMessage`) resets every time. We want one guest's wasm instance — its **linear memory (= the
QuickJS heap)** plus its runtime context — to STAY ALIVE between messages: set it up once, then re-enter a
dispatch entry point per message with memory persisting.

## Mechanism (Washy side) — DONE, in this change

`call_io` does setup → invoke → restore (in `after`). Persistence is the opposite of the restore: set up,
run setup, then **capture** the live context into a handle instead of tearing it down. Three new functions
in `lib/washy.ex`:

```elixir
# Instantiate + run setup ("_start"), KEEP memory/globals/table/rt alive, capture into a handle.
@spec instance_start(Washy.t(), name :: String.t(), args :: [integer], opts) ::
        {:ok, Instance.t(), stdout :: binary}
        | {:exit, code :: integer, stdout :: binary}
        | {:trap, reason :: atom}
def instance_start(mod, name \\ "_start", args \\ [], opts \\ [])

# Re-enter export `name` on the SAME instance (memory/globals reused), fresh fuel per call.
@spec instance_invoke(Instance.t(), name :: String.t(), args :: [integer], opts) ::
        {:ok, result, stdout, Instance.t()}
        | {:exit, code, stdout, Instance.t()}
        | {:trap, reason, Instance.t()}
def instance_invoke(inst, name, args \\ [], opts \\ [])

# Drop the handle (atomics GC-reclaimed). :ok.
def instance_free(inst)
```

### The instance handle

```elixir
defmodule Nexus.Washy.Instance do
  defstruct [:mod, :mem, :mem_pages, :max_pages, :globals, :table, :rt]
end
```

It captures exactly what `call_io` threads through the process dict and would otherwise tear down:

| field       | what                                  | mutation across invokes                          |
|-------------|---------------------------------------|--------------------------------------------------|
| `mod`       | decoded module (immutable, shared)    | never                                            |
| `mem`       | `:washy_mem` linear-memory atomics    | **swapped** by `memory.grow` (realloc) — recaptured |
| `mem_pages` | logical page-count atomics            | mutated in place (same ref)                      |
| `max_pages` | growth ceiling                        | never                                            |
| `globals`   | mutable globals atomics               | mutated in place (same ref)                      |
| `table`     | call_indirect func table              | stable (recaptured defensively)                  |
| `rt`        | interpreter runtime map               | fuel/depth replaced per call                     |

### Re-entry discipline

`instance_invoke` installs the held context into the process dict (`:washy_mem`, `:washy_globals`,
`:washy_table`, `:washy_mem_pages`, `:washy_max_pages`, `:washy_rt`, `:washy_last_fuel`), allocates a
**fresh fuel + depth** atomics for this call (each delivery gets its own budget), invokes the export via the
same `call_fn` the interpreter uses, then **snapshots** the (possibly grown) `:washy_mem` + table back into
the returned handle, and restores the caller's prior dict context in `after`. Both `instance_start` and
`instance_invoke` capture/restore the caller's full run context, so they are nesting-safe (an instance op
inside another washy run leaves the outer run's dict intact — same guard `call_io` uses for the wb-6c2y
class of bug).

## Ownership model — single-process, no shared mutable memory

An `Instance` is OWNED by exactly one BEAM process: the actor `GenServer`. The struct is an immutable
snapshot; the mutable state lives in `:atomics` (off-heap cells). `:atomics` refs are shareable handles,
but **only the owning process ever installs them into its dict and invokes the export** — there is no
cross-process access, so there is no shared-mutable hazard. This is why `instance_invoke` runs the export
**IN THE OWNER PROCESS DIRECTLY**, not in a `Sandbox` Task:

- A `Task` gets a fresh process dict; the persistent run context (`:washy_mem` et al.) would not be present,
  defeating the whole point. The Sandbox's `@ctx_keys` copy is a *snapshot* — fine for one-shot, wrong for
  a live instance whose memory must be the canonical owned cell.
- The owner process already provides BEAM isolation: one actor = one process = its own heap; a trap is a
  caught exception (`{:trap, reason, inst}`); a crash is contained by the supervisor. We do not need a
  second process per delivery.
- Wall-clock bounding of a delivery is the GenServer's concern (it can run the invoke under its own timer /
  `Task.yield` if a hard wall-clock kill is wanted); fuel + call-depth + memory are bounded per-call inside
  `instance_invoke` exactly as in `call_io`.

`memory.grow` reallocates the backing atomics and stores the new ref in the dict; `instance_invoke`
recaptures it into `new_instance.mem`, so the owner MUST thread `new_instance` forward (the input handle's
`mem` is stale after a grow). All other state is mutated in place.

## Actor wiring (DONE, in this change) — `lib/washy/actor.ex`

- `init/1`: state carries `instance: nil`.
- `boot/1` (`:js`): decodes `qjs-run.wasm`, sets the in-process guest context (argv/stdin/vfs/fds with the
  script as `/work/main`), and `instance_start(mod, "_start", …)` ONCE — keeping the live instance in
  `state.instance`. `_start` evals the script (registering `Beam.onMessage`) and returns without tearing
  down. If the wasm isn't provisioned / lacks persistent setup, `instance` stays `nil`.
- `deliver/3` (`:js`):
  - **persistent path** (`state.instance` is an `%Instance{}`): stash the message in `:washy_beam_inbox`,
    `instance_invoke(inst, "wb_dispatch", …)` — NO script re-run — thread the returned `inst2` into state.
  - **fallback** (`instance == nil`, qjs-run.wasm not yet rebuilt): the old behavior — re-run
    `script <> ";__beam_dispatch();"` via the Sandbox (state does not persist; documented limitation).
- `terminate/2`: `instance_free(state.instance)`.

## What the parent must change in `compilers/js/harness_run.c` (CANNOT do here)

The mechanism above is live and tested; the JS side awaits a `qjs-run.wasm` rebuild. Exact changes:

1. **Split setup out of `_start`/`main` and stash the context statically.** Today `_start` creates the
   `JSRuntime*`/`JSContext*`, registers the `__beam_*` host imports + the `Beam` global, evals the guest
   script, then frees the runtime and returns. Change it to:
   - Create `JSRuntime*`/`JSContext*`, register the `__beam_*` imports + the `Beam` global, eval the guest
     script (so `Beam.onMessage(cb)` runs and the callback is held by the QuickJS context).
   - Stash the live context in file-scope statics and **RETURN WITHOUT freeing**:
     ```c
     static JSRuntime *g_rt = NULL;
     static JSContext *g_ctx = NULL;
     static JSValue   g_on_message = JS_UNDEFINED;  /* the registered onMessage callback */
     ```
   - `_start` becomes "setup only": it leaves `g_rt`/`g_ctx`/`g_on_message` populated and returns 0.

2. **Add a new wasm export `wb_dispatch`.**
   - **Export name:** `wb_dispatch` (must match the string passed to `instance_invoke` in `deliver/3`).
   - **Signature:** `() -> i32` (no params; return 0 on success, non-zero on a guest-side error). Add
     `__attribute__((export_name("wb_dispatch")))` (or a `-Wl,--export=wb_dispatch` link flag) so it is a
     real wasm export the decoder sees in the export section.
   - **Body:** using the stashed `g_ctx`:
     ```c
     __attribute__((export_name("wb_dispatch")))
     int wb_dispatch(void) {
       /* pull the delivered message JSON from the host via the existing beam_recv import,
          parse it to a JSValue, and call the registered onMessage callback */
       /* (this is the C half of what the prototype called __beam_dispatch()) */
       char buf[BEAM_RECV_MAX];
       int len = beam_recv((int)(intptr_t)buf);        /* host writes inbox JSON, returns length */
       JSValue msg = JS_ParseJSON(g_ctx, buf, len, "<inbox>");
       JSValue ret = JS_Call(g_ctx, g_on_message, JS_UNDEFINED, 1, &msg);
       int rc = JS_IsException(ret) ? 1 : 0;
       JS_FreeValue(g_ctx, ret);
       JS_FreeValue(g_ctx, msg);
       js_std_loop(g_ctx);   /* drain microtasks/jobs queued by the handler, as the prototype did */
       return rc;
     }
     ```
   - It must NOT create or free a runtime — it reuses `g_ctx`, so the QuickJS heap (and thus every guest
     `let`/closure) persists across calls. This is what makes `let count = 0; Beam.onMessage(m => count++)`
     count up across messages.

3. **Lifetime / teardown.** There is intentionally no exported "free" function the host calls — the guest's
   state lives in the wasm linear memory, which is owned by the Washy `Instance` and reclaimed when the
   actor's `terminate/2` drops the handle (`instance_free`). If a clean QuickJS shutdown is desired (e.g.
   to run finalizers), optionally add an export `wb_teardown() -> void` that does
   `JS_FreeValue(g_ctx, g_on_message); JS_FreeContext(g_ctx); JS_FreeRuntime(g_rt);` and have
   `terminate/2` call `instance_invoke(inst, "wb_teardown")` before `instance_free`. Not required for
   correctness (dropping linear memory is sufficient), so the host does not depend on it.

### Wiring once the rebuilt wasm exists

No further Elixir change is needed — `boot/1` already calls `instance_start(mod, "_start")` and `deliver/3`
already calls `instance_invoke(inst, "wb_dispatch")`. The moment `qjs-run.wasm` exports `wb_dispatch` and
`_start` returns without freeing, the persistent path activates automatically and the fallback (script
re-run) is bypassed. Confirm by asserting that two `Beam.send`s to a guest holding `let count=0;
Beam.onMessage(m => { count++; Beam.send(test, count); })` reply `1` then `2`.

## Validation (this change)

`test/washy_instance_test.exs` proves the MECHANISM without a qjs rebuild, using a hand-built counter
module (memory-backed `inc()`/`get()` + a mutable-global-backed `bump()`):

- `inc` three times on the SAME instance returns 1, 2, 3 → memory persisted across export calls.
- a second `instance_start` is independent (per-instance state, not global).
- mutable globals persist across invokes too.
- `instance_free` is `:ok`; instance ops don't clobber an outer run's `:washy_rt`/`:washy_mem`.

All 5 pass; regression `mix test test/washy_fuzz_test.exs test/washy_actor_test.exs` stays green (16 tests).

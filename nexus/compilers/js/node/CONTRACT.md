# Adding a Node core module — the Wave-1 fan-out contract (wb-5q8w spine)

Washy runs QuickJS-compiled-to-wasm guests inside the BEAM. A guest's `require('<mod>')` resolves Node
core modules registered here. The host side is **fan-out-shaped**: a new I/O module is **pure Elixir +
pure JS in its own files** — it touches **no shared file** (`harness_run.c`, `washy.ex`, `host_io.ex`,
`build.sh`, `node/0*.js` are owned by the integrator). This is what lets many agents build in parallel.

## The two seams

1. **The CommonJS registry.** Every `node/NN_<mod>.js` runs inside ONE shared IIFE (`00_open.js` opens it,
   `99_require.js` closes it). Register your module with `def('<mod>', <exports>)`. Files are concatenated
   in **filename order** — pick a free numeric prefix (gaps are intentional). `var`/`function` you declare
   are in-scope for later files (e.g. `EventEmitter` from `20_events.js`).

2. **The generic host bridge** (for modules that need the host — fs/net/crypto, not pure-JS ones):
   - JS: `__host('<concern>_<op>', [args])` → **synchronous** JSON round-trip, returns a JSON-able value.
   - JS: `__host_async('<concern>_<op>', [args])` → returns a **Promise**, resolved later by the host.
   - These route **by convention** to `Nexus.Washy.Host<Concern>`: prefix `fs`→`HostFs`, `net`→`HostNet`,
     `crypto`→`HostCrypto`. No registry — the module name IS the wiring.

## Writing the Elixir concern module — `lib/washy/host_<concern>.ex`

```elixir
defmodule Nexus.Washy.HostCrypto do
  # SYNC: receives the decoded JSON args list, returns any JSON-able term (the guest gets it back).
  def call("crypto_hash", [algo, data_b64]) do
    %{"digest" => Base.encode64(:crypto.hash(algo_atom(algo), Base.decode64!(data_b64)))}
  end

  # ASYNC (optional): kick off the work, then resolve the guest promise `id` later.
  def call_async("net_connect", [host, port], id) do
    actor = Nexus.Washy.Actor.beam_self()             # capture BEFORE spawning a Task
    Task.start(fn ->
      result = do_connect(host, port)
      Nexus.Washy.Actor.io_complete(actor, id, result)   # resolve; pass ok?: false to reject
    end)
  end
end
```

Binary data crosses the bridge **base64-encoded** (JSON-safe) — see `host_fs.ex`. Raw guest-memory access
is available via `Nexus.Washy.HostIO.read/2` + `write/2` for the rare pointer-level concern.

## Writing the JS shim — `node/NN_<mod>.js`

```js
// runs inside the shared IIFE; def() registers it for require().
function readFileSync(path){ var r = __host('fs_read', [path]); if(!r.ok) throw ...; return Buffer.from(r.b64,'base64'); }
def('fs', { readFileSync: readFileSync, /* ... */ });
```

`Buffer`, `TextEncoder`/`TextDecoder`, `queueMicrotask`, `process`, `setTimeout` are all available globals.
For async, wrap `__host_async(...).then(...)`; callback-style APIs defer with `queueMicrotask`.

## The reference implementation

`fs` is the template: `lib/washy/host_fs.ex` + `compilers/js/node/55_fs.js` + `test/washy_fs_test.exs`,
over the existing `Nexus.Washy.VFS`. Copy its shape.

## The async-completion contract (how async I/O actually re-enters the guest)

Host op finishes → `Actor.io_complete(actor, id, value, ok?)` messages the owning guest actor → it
re-enters the live QuickJS instance at the `wb_complete` export with `{id, ok, value}` → the pending
promise resolves/rejects. Timers ride the same spine via `wb_timer`. You never touch this plumbing —
just call `io_complete` from your `call_async`.

## Testing

Mirror `test/washy_fs_test.exs`: run guest JS via
`Nexus.Washy.Sandbox.run_command({:interp, "compilers/js/qjs-run.wasm", js}, "", fuel: 50_000_000_000, timeout_ms: 60_000)`,
guard with a `typeof __host`/`typeof require('<mod>')` probe so it **skips** when the local `qjs-run.wasm`
predates your module (it's gitignored; the **integrator rebuilds** it via `bash compilers/js/build.sh`
and runs the full suite). `mix compile` passing is your local hard gate.

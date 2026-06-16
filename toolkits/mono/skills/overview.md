# mono — overview

# When to use this
NETWORK: none
DESTRUCTIVE: no
OS: any (wasm)
COST: free

  You have RGBA pixel bytes and want them grayscaled in a hot loop — many
  frames, one instance. This is the reference `#+EXEC: kernel` toolkit; read it
  to learn the kernel shape even if you never need grayscale.

# The mental model

  A KERNEL is the opposite of a `command`: a command pays a fresh wasmtime
  Store + WASI stdio round-trip per call; a kernel is instantiated ONCE and
  called per frame through a fixed memory arena (write input, call
  `process(len)`, read output). Use a kernel when per-call overhead would
  dominate — media frames, render tiles, codec passes.

# Workflow

  1. Build + register (once):

## Build the kernel in-sandbox and register it
```bash
     work toolkit build mono
```

  2. Loop it engine-side (the hot path):

## Open once, call per frame (Elixir, via Workbooks.Kernel)
```elixir
     {:ok, k} = Workbooks.Kernel.open_named("mono", arena: :exports)
     {:ok, gray} = Workbooks.Kernel.call(k, rgba_frame)
     Workbooks.Kernel.close(k)
```

  3. Or one-shot from any client (desktop renderer, scripts):

## One frame over RCP (base64 in/out)
```bash
     work rt post "/rcp/kernel/run?name=mono" '{"b64":"<base64 RGBA>"}'
```

# Common pitfalls

  1. Sending more than 1 MiB — the arena is CAP-bounded; `process` returns 0.
     Tile your frames.
  2. Treating it as a command — `mono` is NOT in CommandRegistry; it has no
     stdio. KernelRegistry only.
  3. Non-RGBA input — quads are grayscaled; a trailing remainder passes through
     unchanged (it is not an error).

# Verification checklist

  - [ ] `work toolkit build mono` reports "registered kernel"
  - [ ] a 4-byte input `[10,20,30,255]` returns `[20,20,20,255]`

# See also

  - `work toolkit show mono` — the manifest + ABI summary
  - runtime/host/kernel.ex — the host side of the ABI (authoritative)

# palette — overview

# When to use this
NETWORK: no
DESTRUCTIVE: no

  The palette is the one set of WASM build/runtime tooling. Each runtime is a pinned
  prebuilt (or build recipe) that runs untrusted source in the capability-gated
  sandbox — no OS process, no host access beyond a granted preopen.

# Build the runtimes (from the committed pinned specs)

## build + register every runtime in the set
```bash
  wb toolkit build palette
```

## or just one
```bash
  wb toolkit build palette python
```

# Run source in the sandbox

```bash
  qjs    /w/app.js
  python /w/app.py
  ruby   /w/app.rb
```

  Each runtime's own resources (stdlib) preopen automatically; grant the script's
  dir as an extra preopen.

# palette — Node.js / npm

# The honest Node story (engine = wasmtime only; see [runtime-engine-wasmtime-only](runtime-engine-wasmtime-only))

  "Node" is not a separate interpreter on wasmtime — there is no drop-in `node.wasm`
  you feed arbitrary files. There are exactly three real options, tiered:

  1. *JS language*  → the `qjs` runtime (QuickJS), already in the palette. Runs any
     standard JavaScript directly: `qjs /w/app.js`.
  2. *npm packages (pure-JS)* → BUNDLE then run on `qjs`. Proven: `bun add ms` +
     `bun build app.js --bundle` → a single file that `qjs` runs in the sandbox
     (verified: the npm `ms` package returns `172800000 2m` via qjs/wasmtime). This
     covers the large class of pure-compute npm libraries (lodash, date-fns, zod, …).
  3. *Full Node (node:fs / node:http / native addons)* → NOT available on wasmtime.
     The only full-fidelity option is Wasmer's Edge.js via WASIX (a second runtime),
     deliberately declined ([runtime-engine-wasmtime-only](runtime-engine-wasmtime-only)). The wasmtime-native
     partial path is `jco componentize` (StarlingMonkey): a JS app → a wasm COMPONENT
     — a build-per-app, growing node-builtin support, not a registered interpreter.

# Run npm code in the sandbox (the proven path)

## bundle an npm-using script to one file
```bash
  bun add <pkg> && bun build app.js --bundle --format=esm --outfile=bundle.js
```

## run the bundle on the qjs runtime (sandboxed; grant the dir)
```bash
  qjs /w/bundle.js
```

# Limits (stated plainly, no pretending)

  - Works: pure-JS / compute npm packages, standard JS, ESM/CJS after bundling.
  - Does NOT work on qjs: `node:fs`, `node:http`, sockets, native addons. Those need
    `jco componentize` (partial, component-per-app) or Wasmer/WASIX (off-engine).

# See also
  - `overview` — the palette runtime set (qjs/python/ruby/go).
  - jco/ComponentizeJS for the JS-app→component build path (separate from the interpreter palette).

# eval-host — the shared StarlingMonkey JS engine

`priv/eval-host.wasm` is the one StarlingMonkey engine `Nexus.JsEngine` runs. JS is fed to its
`run(input)` export as **data** (js_dom/browse + the Elixir-toolkit lane). This dir is the **build
recipe**; the artifact is gitignored (~12.5MB), built on the CI/build runner — like `coreutils.wasm`
/ `work-toolchain.wasm`. Staged by `nexus/scripts/stage-eval-host.sh` (a step in `nexus-image.yml`).

## The shared host-broker seam (one import, an op vocabulary)

The engine imports the single synchronous `wb:jseval/broker.host-call: func(req: string) -> string`,
bound to `globalThis.__wbHostCall`. EVERYTHING the guest needs from the host rides this one seam as an
`op`-dispatched JSON envelope (`{"op":"…",…} -> {"ok":true,…}`): node-compat ops (exec/fs/creds) AND
toolkit capability ops (store/load/cache.*/fetch/complete/emit). One engine, one import, one
vocabulary — new caps need NO engine rebuild, just a new `op` handler + a guest wrapper.

The committed shims in `nexus/compilers/js/shims-sm` (child_process/fs/dock_auth) already call
`globalThis.__wbHostCall`; this engine provides that seam, and `Nexus.Toolkit.Caps` is the live
host-broker dispatcher. Node-compat ops (exec/fs/creds) join the same vocabulary here as that lane
is built in `nexus/`.

## Files

* `evalhost.wit` — `package wb:jseval; interface broker { host-call: func(req:string)->string }
  world workbook { import broker; export run: func(input:string)->string }`
* `evalhost.js` — binds `host-call` → `globalThis.__wbHostCall`; `run(input)` evals + awaits.

## Build (CI/build runner, native node — never in a nexus)

```bash
npx -p @bytecodealliance/jco -p @bytecodealliance/componentize-js \
  jco componentize evalhost.js --wit evalhost.wit --world-name workbook -o ../../priv/eval-host.wasm
```

`stage-eval-host.sh` wraps this (idempotent; pinned scoped packages). Native node/jco runs ONLY here;
at runtime every nexus loads pure wasm under wasmtime.

## Runtime wiring

* `Nexus.JsEngine.eval/2` wires the `wb:jseval/broker.host-call` import to `opts[:broker]` (a 1-arg
  `(req_json) -> resp_json` fn). Default DENIES every op, so a plain eval (js_dom) has no capability
  surface.
* `Nexus.Toolkit.Caps.broker/2` is the toolkit `host-call` closure — path-scoped to
  `{operator, application, component}` + grant-filtered; `host_js/1` is the guest `$host` binding
  (wrappers over `__wbHostCall`).
* `Nexus.Toolkit.Js.invoke/4` threads `opts[:path]` + `opts[:grants]` → the broker + `$host`.

So a toolkit runs with real path-scoped caps on the same seam the rest of the system uses.

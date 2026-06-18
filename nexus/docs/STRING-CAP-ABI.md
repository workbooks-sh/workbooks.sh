# String-typed host capabilities — the canonical-ABI nut

Scalar host caps are turnkey (a unit imports `now()`, the Dock supplies it — see `layers()`).
The real caps (`net`/`kv`/`llm`) are **string-typed**, and that's a genuine research nut.

## What works
- A unit declaring `extern "C" { fn log(ptr: *const u8, len: usize); }` compiles, and the
  `env→$root` import rewrite + `wasm-tools component embed/new` against `import log: func(msg:
  string)` **build a valid component** — the component model *accepts* the mapping of a lowered
  `(ptr, len)` core import to a high-level WIT `string` import.

## What fails
- At runtime: `wasm trap: unreachable … signature_mismatch:log`. The component's import
  trampoline expects a precise core import signature for `func(msg: string)` that mrustc's
  `fn log(ptr, len)` (core type `(param i32 i32)`) does not match.

## Why (the real shape of the problem)
- The canonical ABI for string params/returns is what `wit-bindgen` generates: the guest must
  call the import with the exact lowered signature the trampoline expects, and **string returns**
  need a `cabi_realloc` export so the host can allocate the returned string in guest memory.
- A bare `extern "C"` decl + mrustc doesn't emit that glue. Options to evaluate next:
  1. **Generate the canonical-ABI shim** for each string cap (the lowered import thunk + a
     `cabi_realloc` export) and inject it into the unit source before compiling — a small,
     targeted wit-bindgen substitute for our fixed cap set.
  2. Confirm the exact expected core signature from `wasm-tools print` of a wit-bindgen-built
     reference component, then match it.
- Start with **param-only** caps (`log`) — no return area, no realloc — then returns.

## Until then
`dock_imports: :live_scalar` in `Nexus.layers/0`. Scalar caps (i32/i64/f64/bool) are fully
turnkey; string caps are scoped here.

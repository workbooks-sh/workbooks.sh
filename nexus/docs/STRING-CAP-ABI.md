# String-typed host capabilities — CRACKED (via the reactor shape)

**Resolved.** String host caps work — proven: a C reactor importing `emit(ptr, len)` against a
WIT `import emit: func(msg: string)` lifts the string correctly; the host received `"hello from
C"`. The blocker was never the string ABI — it was the **rust command shape** (libstd + WASI +
the command adapter) polluting the import space. In a clean **reactor** (no command machinery,
no WASI), `(ptr, len)` → WIT `string` lifts cleanly with a plain `component new` (no adapter).

So string caps are now a **wiring task with a proven mechanism**, not a research nut:
- **C units** (the C lane already emits reactors) — works today; the C compiler now takes
  `allow_undefined` so externs become imports the Dock satisfies.
- **The remaining wiring:** map a unit's **grant** (e.g. `grant: [llm]`) → the Dock's *known*
  WIT signature for that cap (`llm-complete: func(prompt: string) -> string`) rather than deriving
  it from the lowered C extern, align the import symbol, rewrite `env→$root` for it, and add the
  string impls to `Dock.impls`. Mechanism proven; this is plumbing.
- **rust string caps** need rust to emit a **reactor** (not the command shape) — the harder path,
  deferred behind the C path which already works.

---
## Original investigation (kept for context)

Scalar host caps are turnkey (a unit imports `now()`, the Dock supplies it — see `layers()`).

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

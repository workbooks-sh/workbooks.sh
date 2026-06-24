# The target ladder — languages, compilers, bundlers, package managers we work through

**Purpose.** A single canonical list of every real-world tool/target we must support, ordered
**easiest → hardest**, each rung paired with a **real, named, version-pinned fixture** (an actual
published package, crate, or app). This is the anti-hand-rolling rule made concrete: when we test a
rung, we use the *real thing* at a pinned version — never a toy we wrote to pass.

> **THE RULE:** every test fixture is a real artifact someone actually publishes. No invented packages,
> no hand-rolled bundlers, no "minimal repro" that dodges the hard parts. If a rung is too hard to do
> with the real tool, that's the finding — record it, don't fake it. (We already deleted one hand-rolled
> CJS bundler for exactly this reason; esbuild does the real work now.)

---

## 0. First clear up the layers (the names that get conflated)

These live at **different layers**. Lumping them together is what makes it confusing — sort them first.

| Term | Layer | What it actually does | Why we care |
|---|---|---|---|
| **ESM** | module *format* | ES Modules: `import`/`export`, the standard format | modern packages ship this; our QuickJS evals a script, so we must bundle ESM → one script (or teach the loader `import`) |
| **CJS** | module *format* | CommonJS: `require`/`module.exports` (Node's original) | older packages; what our esbuild lane emits today (IIFE/CJS) |
| **tsc** | type-checker + transpiler | TypeScript → JS, with type-checking | "run TS" needs this (or esbuild's TS strip); we already run `typescript.js` in QuickJS |
| **esbuild** | bundler + transpiler | resolve `require`/`import` graph → 1 file; TS/JSX strip; minify. Go binary. | ✅ our real bundler (wasm, under wasmtime) |
| **swc** | transpiler | Rust-based Babel replacement (TS/JSX → JS), very fast | alt to Babel/esbuild-transpile; what Next.js uses |
| **Babel** | transpiler | the original JS transpiler (JSX, new→old syntax) via plugins | Solid's compile uses it (we vendor `babel.js`) |
| **Rollup** | bundler | ESM-first bundler, best tree-shaking; library-oriented | Vite uses it for *production* builds |
| **Terser** | minifier | shrink JS (rename, dead-code) | the `--minify` step |
| **Vite** | dev server + build *tool* | esbuild (dev) + Rollup (prod) + plugins; the app build orchestrator | the thing real framework apps build with |
| **npm / pnpm / yarn** | package *managers* (JS) | resolve + fetch + lock a dependency graph into `node_modules` | the "add a package" experience; pnpm = content-addressed store, monorepo-friendly |
| **Cargo** | package manager + build (Rust) | fetch crates, resolve features, drive rustc | the Rust "add a package + build" experience |
| **pip / uv** | package managers (Python) | fetch wheels/sdists, resolve | the Python equivalent |
| **TanStack** | framework *family* | Router / Query / Table / Start (full-stack React on Vite) | a **leaf app** that sits on top of ALL of the above |
| **React / Solid / Svelte / Preact / Vue** | UI frameworks | the component runtime an app is written in | what the leaf app is authored in |

**The organizing distinction (decides where a thing runs):**
- **Tools we RUN to produce an artifact** (compilers, bundlers, package managers) = **TRUSTED**. Run under
  wasmtime today; the goal (epic `wb-wzdq`) is to run them in Washy too. Difficulty = how demanding their
  wasm runtime is (C-thin-WASI easy → Go-full-runtime hard).
- **Artifacts we RUN as the program** (the bundled app, the compiled CLI) = **UNTRUSTED**. Run in Washy.
  Difficulty = what runtime the *output* needs (a static JS bundle is easy; a compiled Go binary is hard).

So "Vite is hard" and "a Vite build's output is easy" are *both true* — different layers.

---

## 1. What makes a rung hard (the difficulty axis)

`difficulty ≈ runtime-demand-of-the-wasm × dep/plugin-graph-complexity × need-for-network/native`

- **Runtime demand:** C/Zig (thin WASI) < Rust (libstd, more WASI) < Go (GC + goroutine scheduler + wide
  WASI — the `<<255,...>>` wall) < anything needing threads/sockets.
- **Graph complexity:** single zero-dep pkg < transitive pure-JS graph < framework w/ plugins < monorepo
  workspace.
- **Network/native:** vendored sources (no net) < registry fetch (net boundary) < native postinstall
  scripts / proc-macros (the genuinely nasty tail).

---

## 2. Lane A — JS/TS: run + bundle (our most-developed lane)

| Rung | Real fixture (pin at adoption) | Tool(s) | Runs where | Status |
|---|---|---|---|---|
| A0 run a plain `.js` | a literal compute script | QuickJS | Washy | ✅ done |
| A1 bundle 1 transitive npm graph | `is-odd`→`is-number` | esbuild (CJS/IIFE) | bundle: wasmtime · run: Washy | ✅ done (`washy_esbuild_test`) |
| A2 zero-dep classics | `ms`, `left-pad`, `nanoid` | esbuild | ″ | next |
| A3 TS → JS, run it | `zod` (TS, type-heavy) | tsc *or* esbuild TS-strip | ″ | partial (tsc runs in qjs) |
| A4 ESM-only package | `chalk@5` (pure ESM) | esbuild `--format=esm` + loader | ″ | needs ESM in run lane |
| A5 large modular ESM (tree-shake) | `date-fns` (import a few fns) | esbuild tree-shaking | ″ | — |
| A6 large CJS | `lodash` | esbuild | ″ | — |
| A7 JSX/component compile | `preact` + a JSX component | esbuild JSX / Babel / swc | ″ | partial (svelte/solid wired) |
| A8 swc transform parity | a TS+JSX file | swc | ″ | — |
| A9 production app build | a real `vite build` app | **Vite** (esbuild+Rollup+plugins) | bundle: wasmtime(Node-ish) · run: Washy | hard — Vite is a Node program |
| A10 framework leaf app | **TanStack** Router/Start app | Vite + React | ″ | hardest JS rung |

Note the cliff at **A9**: Vite is a *Node* program (needs a Node runtime, not just QuickJS). Its *output*
is trivial to run; running *Vite itself* in-sandbox is the hard part (Node-in-wasm, or run under wasmtime
with a Node shim). Until then, A0–A8 (esbuild-class, QuickJS-runnable) are the reachable band.

---

## 3. Lane B — compiled languages: run a real compiled program in Washy

Difficulty is dominated by the **language runtime's** wasm demands.

| Rung | Real fixture | Compiler | Status / blocker |
|---|---|---|---|
| B0 C compute CLI | our Collatz CLI; `coreutils` | clang→wasm | ✅ done (Collatz tiered; coreutils runs) |
| B1 Zig CLI | a small Zig program | zig→wasm | lane exists (`zig.ex`) — pick a fixture |
| B2 Rust CLI (no_std-ish) | `itoa`/`ryu` demo, then a small bin | mrustc/rustc→wasm | lane exists (`rust.ex`) |
| B3 Rust CLI w/ libstd | `ripgrep`-lite, `sd`, `hexyl` | rustc→wasm | std WASI coverage |
| B4 Swift CLI | a small Swift program | swiftc→wasm | lane exists (`swift.ex`) |
| B5 TinyGo CLI | a TinyGo program | tinygo | easier than full Go |
| B6 **full Go** CLI | esbuild itself; a Go `hello` | go→wasip1 | ⛔ **the runtime wall** (`wb-f7im`): GC + scheduler + wide WASI |

B6 is the same gap as running esbuild-in-Washy — close it once, both unlock.

---

## 4. Lane C — package managers: the "add a dependency" experience

The honest split: **resolution + build** can run in-sandbox; **fetch** is a genuine network boundary.

| Rung | Real fixture | Tool | Notes |
|---|---|---|---|
| C0 vendored node_modules → bundle | `is-odd` graph | esbuild | ✅ done (no fetch; sources vendored) |
| C1 registry fetch + lock (JS) | install `ms` from npm | npm/pnpm resolver | who runs the resolver? Node program → A9-class, or build our own resolver |
| C2 pnpm workspace/monorepo | a 2-package workspace | pnpm | content-addressed store semantics |
| C3 Cargo add + build | a crate with 1 dep (`rand`) | cargo + rustc | fetch crates.io + feature resolution + build (B-lane) |
| C4 pip/uv install + run | `requests` or stdlib-only | pip/uv + CPython-wasm | Python lane exists (`python.ex`) |
| C5 native postinstall / proc-macros | (the nasty tail) | — | record honestly; may stay out-of-scope |

---

## 5. How we climb (process)

1. **Pick the next rung** (lowest unchecked). File a bd issue, pin the fixture's exact version in it.
2. **Use the real artifact** — fetch the real package/crate/app; never synthesize one.
3. **Prove it** the standard way: correct output, oracle-consistent (interp == tiered), record numbers.
4. If the real tool can't run in-sandbox yet, that's a **coverage finding** → it feeds the runtime epics
   (`wb-f7im` WASI/Go coverage, `wb-wzdq` from_asm speed), not a reason to fake the test.
5. Update the status column here. This file is the map; bd holds the live work.

**Cross-refs:** runtime speed/substrate = `nexus/reference/beam/` + epic `wb-wzdq`. WASI/Go coverage =
`wb-f7im`. JS run lane = `lib/compilers/js.ex` + `lib/washy/sandbox.ex`. Bundler = `lib/compilers/esbuild.ex`.

# Porffor — opt-in "fast JS subset" lane (RESEARCH + PLAN)

Status: **research / plan only.** Nothing here is implemented. Porffor is **opt-in
acceleration** for a JS *subset*; **quickjs stays the default and the fallback** for all JS.
This document grounds why, how it would slot in, and the smallest viable first step.

---

## 0. The one-line thesis (why this is worth doing)

We compile untrusted code to WASM and run it emulated on `Nexus.Washy` (pure-Elixir wasm
interpreter + wasm→BEAM transpiler). Two layerings exist for JS:

- **quickjs (today):** a JS *engine* compiled to wasm. We embed the user's JS as bytes, the
  wasm `main()` *interprets* it. That is **interpreter-on-interpreter** — Washy interprets a
  wasm that interprets JS. Slow, but runs **all** JS.
- **Porffor (proposed):** an AOT compiler that turns the JS *program itself* directly into a
  wasm module — **one layer**. Washy then interprets (or transpiles to BEAM) that wasm
  directly, with no inner JS interpreter. Fast, and our wasm→BEAM tier can make it near-native.
  But Porffor supports only a **subset** of JS, so it cannot be the only path.

So: **try Porffor; on any unsupported-feature error, fall back to the proven quickjs lane.**

---

## 1. What Porffor is — maturity, subset, license

- **Repo:** https://github.com/CanadaHonk/porffor — "An ahead-of-time JavaScript compiler."
- **Site:** https://porffor.dev/
- **License: MIT** (copyright 2023–2025). Clean for vendoring.
- **What it is:** a from-scratch AOT optimizing **JS/TS → Wasm/C** compiler, *written in JS*.
  Only the parser is external (Acorn); it does **not** use Binaryen — it emits the wasm bytes
  itself. Output is reported 10–30× smaller/faster than interpreter-bundling approaches,
  because it compiles the program instead of shipping an engine.

### Maturity — treat as EXPERIMENTAL

- The project explicitly states it is **"not yet intended for serious use"** and
  **"Expect nothing to work!"** It is a research compiler.
- **Versioning scheme is a conformance signal:** the middle version number is the **Test262
  pass-rate percentage**. Porffor runs Test262 every commit to track conformance. (So a
  version like `0.x.y` literally encodes "x% of Test262 passes" — read it before trusting a
  given build; the unsupported set is large and moving.)
- It moves fast and breaks; **pin a vendored version** and re-verify on bump.

### Subset — what works / what does NOT (be concrete)

Works (the AOT-friendly core): primitives (numbers, strings, booleans), arithmetic and the
operators, `if`/`for`/`while`/control flow, functions, `console.log`, arrays and basic
objects, TypeScript syntax (types are erased). The `bench/` directory in the repo is the
canonical "things that compile" corpus — **use it as the supported-feature oracle.**

Notably **does NOT** work / throws or miscompiles:

- **`eval()` / `new Function()`** — impossible by construction (it is AOT, there is no
  runtime compiler). Hard "no", will not be added.
- **`Promise` / `async` / `await`** — "limited async support, known bugs." Treat as unsupported.
- **No closures over outer scopes** — "no variables between scopes (except args and globals)."
  This is a *big* one: idiomatic JS leans on closures constantly; many programs will hit it.
- Large swaths of the **standard library / built-ins** are partial or missing (whatever the
  current Test262 % does **not** cover). Regex, full `Intl`, many `Array`/`String`/`Object`
  methods, getters/setters, proxies, generators, etc. are likely gaps depending on version.
- Anything dynamic-typing-heavy or relying on full prototype semantics is risky.

**Conclusion:** Porffor compiles a *simple, mostly-static* JS subset. It is an accelerator for
the easy 60–80% of small programs, never a replacement. **Any compile error ⇒ fall back.**

### I/O contract — THE key integration wrinkle

Porffor's wasm **does not use WASI by default.** It does **not** export a WASI `_start` and
does **not** import `fd_write`; it emits its **own host imports** (e.g. a print/log import)
and is "mostly unusable on its own" without a host that provides them. This is the single
biggest difference from our existing JS lane, which produces a **WASI command module**
(`crt1-command.o` → `_start`, stdin→stdout via WASI). Two ways to bridge (decide in step 0
of implementation):

1. **Provide Porffor's imports on Washy** — implement the small import surface Porffor expects
   (its log/print function) as host functions in `Nexus.Washy`, capturing writes into the
   per-run stdout buffer. Cleanest long-term; verify the exact import names/signatures from a
   real `porf wasm` output (`wasm-tools print`/`objdump` the module — see step 1).
2. **Ask Porffor to target WASI / a known shape** if a flag exists, OR post-process the module
   with `wasm-tools` (already vendored at `compilers/wasm-tools/`) to rename/shim imports onto
   the WASI surface Washy already implements. More moving parts; only if (1) is awkward.

Pick (1) unless inspection shows Porffor already emits a WASI-shaped module.

---

## 2. How to invoke Porffor → standalone `.wasm`

Porffor ships an npm package with a `porf` CLI. The compile-to-wasm command is:

```
porf wasm path/to/script.js out.wasm
```

(Sibling modes, not needed here: `porf native in.js out` → native binary via Porffor's own
`2c` wasm→C compiler; `porf c in.js out.c` → C source.)

- **Install:** `npm install -g porffor@latest` (or local/vendored — see below).
- **Runtime dependency: Node.** Porffor itself is a JS program; the CLI runs on Node. This is
  a **build-time/host** dependency (it runs on the trusted host to *produce* the wasm), **not**
  inside the sandbox. That is fine and consistent with how other lanes shell out to a host
  toolchain — the *output* wasm is what runs untrusted on Washy. (Contrast: `ts`/`svelte`
  transpilers run *in-sandbox* on qjs/SpiderMonkey precisely because they process untrusted
  source; Porffor compiling trusted-author block bodies on the host is acceptable, but if we
  want zero host-Node we could later run Porffor itself in-sandbox on qjs — out of scope for v1.)
- **Offline / vendored:** MIT-licensed, pure JS, parser = Acorn. It can be vendored under
  `compilers/js/porffor/` and run with a pinned Node, fully offline. Pin the version (the
  Test262-% encoding makes "latest" a moving target). Confirm the exact CLI entrypoint of the
  pinned tarball (`porf` bin → its JS entry) when vendoring.

---

## 3. How it slots in alongside quickjs (the decision flow)

The JS lane (`Nexus.Compilers.Js.js_compile_to_wasm/3`,
`nexus/lib/compilers/js.ex:22`) becomes a **router**:

```
js_compile_to_wasm(source, opts, root):
  if porffor_enabled?(opts) and not dock_caps_requested?(opts):   # opt-in gate
    case Porffor.compile(source):                                 # new sub-lane
      {:ok, wasm_path}      -> {:ok, wasm_path}                   # FAST one-layer path
      {:error, :unsupported}-> quickjs_compile(source, opts)      # FALL BACK, loud-debug log
      {:error, other}       -> quickjs_compile(source, opts)      # any Porffor failure → fall back
  else:
    quickjs_compile(source, opts)                                 # DEFAULT (today's build/4)
```

Key rules:

- **Opt-in only.** Gated by a `deploy`-block config knob read via `Nexus.Config` (NO env var,
  per the no-JSON / config-as-`.work` rule), e.g. `js_fast_path: true`, default **false**.
  Possibly also a per-unit facet later. Until a unit/site opts in, behavior is byte-identical
  to today.
- **Caps force quickjs.** When the unit grants capabilities (`dock: true`, the
  `harness_dock.o` import surface), use quickjs — Porffor has no equivalent dock harness in v1.
  (`granted?/1` already decides this at `nexus/lib/compile.ex:341`.)
- **Fallback is total and silent-to-the-user.** Porffor erroring is *normal* (it is a subset);
  it must never surface as a user-facing failure — it just means "this program wasn't in the
  fast subset," and quickjs runs it. Log at debug for observability.
- **`:unsupported` is the contract.** The Porffor wrapper classifies its failures into
  `{:error, :unsupported}` (anything compile-side: parse OK but feature missing, link gap,
  import mismatch) so the router treats every Porffor miss as "fall back," never as a hard error.
- **TS reuses it for free.** `ts_unit` already transpiles TS→JS then calls
  `js_compile_to_wasm` (`nexus/lib/compile.ex:343-347`). Since Porffor also accepts TS
  directly, a later optimization is to hand TS straight to Porffor; v1 can keep TS→JS→router.

---

## 4. Integration points in `nexus/lib` (file:line)

- **`nexus/lib/compilers/js.ex:22`** — `js_compile_to_wasm/3`. This is the seam. Add the
  Porffor branch at the top of the `cond`/before `build/5`; `build/5` (`:40`) remains the
  quickjs path untouched. The new Porffor sub-lane lives either as private fns here or a new
  sibling module `Nexus.Compilers.Js.Porffor` (preferred for DRY/least-blast-radius).
- **`nexus/lib/compile.ex:341`** — `js_unit/1` calls `js_compile_to_wasm(body, dock: ...)`.
  No change needed if the router lives inside `js_compile_to_wasm`; the opt-in/caps decision
  is read here (`granted?/1`) and can be threaded as an extra opt.
- **`nexus/lib/compile.ex:343-347`** — `ts_unit/1` (TS→JS→js lane). Inherits Porffor for free
  via the router; optional later direct-TS optimization.
- **`nexus/lib/washy/sandbox.ex:106-113`** — `run_command/3` (binary wasm path) →
  `exec_module/5` (`:129`). This RUNS the produced wasm. The quickjs lane produces a WASI
  command module that this already handles. **Porffor's non-WASI import surface must be made
  runnable here**: either Washy provides Porffor's print/log import (preferred — see §1 I/O),
  or the wrapper shims the module to WASI before returning. This is the one place that needs a
  genuinely new capability, not just routing.
- **`nexus/compilers/wasm-tools/`** — vendored `wasm-tools`, available for inspecting
  (`print`) and, if needed, shimming/renaming the imports of Porffor output.
- **`nexus/lib/wasm/aot.ex`** (`Nexus.Wasm.Aot`) — the tier that transpiles hot wasm→BEAM.
  This is *where the Porffor win compounds*: a one-layer Porffor module is exactly the kind of
  module this tier can make near-native, unlike the quickjs interpreter loop. No change to
  enable; note it as the payoff.

---

## 5. First-step task list (smallest-viable-first)

Each step is independently green and verifiable. Do them in order.

1. **Vendor + pin Porffor.** Install a pinned `porffor@<ver>` under
   `nexus/compilers/js/porffor/` (vendored, offline-runnable on the host's Node). Record the
   exact `porf wasm` entrypoint. Add a `take` for it in the staging allowlist if it must ship
   in the compilers image (`runtime/scripts/stage-tools.sh`) — but v1 can keep it host-local.
   Verify by hand: `node .../porf wasm hello.js hello.wasm` produces a non-empty `.wasm`.

2. **Inspect the I/O contract.** `wasm-tools print hello.wasm` → record the **exact import
   module/name/signature** Porffor emits for output (log/print) and confirm there is **no**
   WASI `_start`/`fd_write`. This determines the §1 bridge. (Pure investigation; no code.)

3. **`Porffor.compile/1`** — one function: JS source → `{:ok, wasm_bytes} | {:error,
   :unsupported}`. Writes source to a temp `.js`, shells `porf wasm` on the host (via the
   existing `Nexus.Sandbox.subprocess_env` / `System.cmd` pattern used in this module),
   reads back the `.wasm`, classifies **any** non-zero/parse/feature failure as
   `{:error, :unsupported}`. Unit-test the happy + the fallback (feed it `eval("1")` → must
   return `{:error, :unsupported}`).

4. **Teach Washy the Porffor import(s).** In `Nexus.Washy` host-import resolution, provide the
   one print/log import found in step 2, routing bytes into the per-run stdout buffer (same
   buffer WASI `fd_write` feeds). Smallest possible surface; only what `console.log` needs.

5. **End-to-end proof test (the headline deliverable).** A test that:
   - takes a simple program — arithmetic + a `for` loop + `console.log` (the canonical
     "in-subset" program),
   - compiles it via `Porffor.compile/1` (asserts `{:ok, _}`),
   - runs the bytes on `Nexus.Washy.Sandbox.run_command/3`,
   - asserts stdout equals the expected output.
   This proves the **one-layer fast path end-to-end** on our own runtime. Add a twin test
   that a closure/`async` program returns `{:error, :unsupported}` and the router yields the
   **same correct output** via quickjs — proving the fallback is invisible and correct.

6. **Wire the opt-in router** into `js_compile_to_wasm/3` behind the `Nexus.Config` knob
   (default off), caps→quickjs. Ship with the knob **off**; flip it on for a dogfood surface
   to gather real subset hit-rate before any default change.

Stop conditions for v1: router + Porffor sub-lane + Washy print import + the two e2e tests
green, knob default-off. No TS-direct, no in-sandbox Porffor, no dock harness — those are
follow-ups.

---

## 6. Non-negotiable: Porffor is an INCOMPLETE subset

- **quickjs remains the default and the universal fallback.** Every JS program must still run.
- Porffor is **opt-in acceleration**, gated by config, default **off**.
- A Porffor compile failure is **expected and silent-to-user** — it means "not in the fast
  subset," not "broken." The router always falls through to quickjs.
- Never let a Porffor gap become a user-visible JS failure. If Porffor can't, quickjs does.

---

## Sources

- Porffor repo — https://github.com/CanadaHonk/porffor
- Porffor site — https://porffor.dev/
- License (MIT) — https://github.com/CanadaHonk/porffor/blob/main/LICENSE

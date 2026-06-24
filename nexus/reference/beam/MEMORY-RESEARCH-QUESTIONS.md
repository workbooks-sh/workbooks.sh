# BEAM VM memory & scaling — research brief for a deep-research third party

**Purpose.** We're building a system ("Washy") that runs *untrusted* code as WebAssembly executed **inside
the Erlang/BEAM VM** (pure-Elixir interpreter + a wasm→BEAM-assembly JIT), instead of in OS containers or
a wasmtime subprocess. The bet is **density + isolation**: thousands of guests as cheap BEAM processes on
one box. Before we push further (and before we take on Node.js / Python / heavier guests), we want an
outside expert opinion on the **memory model, the GC, and the hard walls** we'll hit, and on a couple of
architectural forks. This doc gives the context, then the questions. Please answer the questions directly,
cite BEAM/ERTS internals where relevant, and flag anything we've gotten wrong.

---

## 1. What we've built (context you need to answer well)

**Two execution lanes, both inside the BEAM (no NIF, no subprocess for untrusted code):**
- **Interpreter** — a pure-Elixir tree-walker over decoded wasm. One guest = one BEAM process.
- **JIT (the new lane)** — we lower a hot wasm function to **BEAM assembly** and compile it in-memory via
  `:compile.forms(asm, [:from_asm])`, then `:code.load_binary/3`. OTP 28, BeamAsm flavor — so the loaded
  bytecode is JIT'd to native machine code at load time. Each compiled function becomes its **own loaded
  BEAM module** with a generated name like `:"washy_asm_<unique_integer>"`.

**How guest state maps onto BEAM today:**
- **Linear memory** (the wasm heap) = a per-process `:atomics` array (`:atomics.new(pages * 8192,
  signed: false)`, 8 bytes/slot, little-endian byte layout), held in the process dictionary under
  `:washy_mem`. `memory.grow` reallocates a bigger atomics and swaps the dict entry.
- **Globals** = another `:atomics` array. **Fuel** = a 1-slot signed `:atomics` counter, decremented per
  loop iteration; trap on `< 0`.
- **i32 / i64 values** = Erlang integers, masked to `2^32` / `2^64` (so i32 stays a fixnum; i64 near the
  top of the range becomes a heap bignum).
- **Compiled-code cache** = `:persistent_term`, keyed `{Transpile, :hot, module_sha, func_index}` →
  `{ModuleAtom, FunAtom, Arity}` (the loaded native MFA). One entry per compiled function, cross-run.
- **The JIT register model**: each function gets a BEAM stack frame (`allocate`/`deallocate`); all
  persistent values live in `y`-registers; calls between guest functions trampoline through a shared
  dispatcher on the process-dict run state.

**Scale target:** thousands of concurrent sub-MB guests on a 1 GB–8 GB box (Fly machines, often few cores),
vs. dozens of containers/microVMs on the same hardware.

---

## 2. The questions

### A. BEAM memory model fundamentals
1. Lay out where each kind of memory lives and how it's reclaimed: **per-process heaps** (young/old
   generational GC), **message area**, **refc binaries** (>64 bytes, off-heap, reference-counted),
   **heap binaries** (≤64 bytes), **`:atomics`/`:counters`** (off-heap, freed when the ref is GC'd?),
   **ETS**, **`:persistent_term`**, **atom table**, **loaded code (BEAM + BeamAsm native)**. For each:
   is it per-process or global? GC'd or manually freed? What triggers reclamation?
2. For our **`:atomics`-as-linear-memory** choice: confirm the lifetime model — the atomics array is
   off-heap and freed when its owning term is garbage-collected by the process that holds the ref. Is
   there a per-array or per-node cap? Allocation/fragmentation behavior for many medium arrays (KBs–MBs)
   created/destroyed as guests come and go? Is there a better primitive (off-heap binary, `enif`-managed
   resource, `mmap`) for "a few MB of mutable guest RAM per process, thousands of them"?

### B. The density & scaling walls (this is the heart of it)
3. **The atom-table wall.** We generate a unique module name atom per compiled function
   (`:"washy_asm_N"`). **Atoms are never garbage-collected** and the table has a hard ceiling (default
   ~1,048,576). At thousands of guests × hundreds of hot functions each, we exhaust it and the node dies.
   - Confirm the failure mode and the exact limit/levers (`+t`).
   - What are the right mitigations? Options we see: (a) a **fixed pool** of pre-declared module-name
     atoms, cycled with `:code.soft_purge` + reload (does reloading over the same module atom leak? how
     many code versions does ERTS keep — 2? what happens to running native code on purge?); (b) **one
     big generated module per guest module** instead of one-per-function (fewer atoms, bigger
     `:compile.forms`); (c) **a single fixed dispatcher module** + data-driven execution (loses the
     per-function-native win); (d) something else. Which is least-bad for a JIT that wants thousands of
     distinct native functions live at once?
4. **Loaded-code memory & purging.** Each `:code.load_binary` adds a module (bytecode + BeamAsm native
   code) to the global code space. With thousands of tiny generated modules: what's the per-module memory
   overhead (code, literal area, export/atom entries, native code)? How does **hot-code purging** work
   for generated modules, and can we evict cold ones safely while others run? Is there a practical ceiling
   on number of loaded modules independent of atoms?
5. **`:persistent_term` growth.** We use it as the cross-run compiled-code cache (one entry per function).
   Each `:persistent_term.put` is documented to be expensive and to trigger a **global GC scan** of all
   processes that hold references. At thousands of entries written over time: what's the real cost curve,
   the memory overhead, and the right eviction strategy? Is persistent_term the wrong home for a
   high-cardinality, evictable cache — should this be ETS instead?
6. **Process density.** Thousands of guest processes, each with: a heap (interpreter state or JIT frame),
   an atomics linear-memory ref, dict entries. What's the realistic floor per **idle** and per **active**
   guest? Where does the BEAM scheduler / run-queue / memory-allocator (`erts_alloc`) start to hurt at
   high process counts on few cores? Any carrier/fragmentation tuning (`+M*` flags) we should know about?

### C. GC behavior under our specific patterns
7. **Bignum pressure.** i64 arithmetic in hot loops produces values that are heap bignums (boxed,
   2–3 words) whenever they exceed the fixnum range (~60 bits). A tight i64 loop could allocate a bignum
   per iteration → frequent young-gen GC. Is this a real cost at our scale, and is there a way to keep
   64-bit guest values unboxed (we currently *can't* use machine i64 directly in BEAM)? Does this argue
   for representing guest i64 as something other than an Erlang integer?
8. **Frame allocate/deallocate.** Our JIT functions `allocate` a stack frame sized to (locals + max
   operand depth) and zero-init every slot up front (so a GC during a call has all `y`-slots initialized).
   Any pathological cost to large frames or to per-call alloc/dealloc in deeply recursive guest call
   chains? Stack growth limits?
9. **Refc binaries & I/O.** Guest stdout/stdin and the (future) SQLite-backed virtual FS move bytes
   through refc binaries. Any binary-leak / late-collection pitfalls (the classic "binary memory grows
   because the owning process rarely GCs") we should design against when a guest streams a lot of output?

### D. Compiled-code lifecycle correctness
10. When we `:code.load_binary` a generated module while an **older version** of a same-named module is
    still executing (if we cycle atoms), what exactly happens — old/current/new code semantics, the
    2-version limit, `check_process_code`, purge timing? We need a safe protocol for reusing module-name
    atoms without killing in-flight native frames.
11. Is generating + loading thousands of modules going to degrade **global structures** (the code index,
    the export table, the literal area) in ways that slow *all* code loading or calling node-wide?

### E. The future-targets question (where does this go?)
We currently run **C/Rust/Zig→wasm** well, and **JS via QuickJS-compiled-to-wasm**. We want a clear-eyed
opinion on heavier targets and a fundamental architectural fork.

12. **Node.js.** Node = V8 (a large C++ JIT'ing engine) + libuv (async I/O) + a big native-addon surface.
    - Is compiling V8 to wasm and running it in our sandbox remotely feasible, or a dead end (V8 JITs,
      wants threads/W^X, is huge)? What's the memory footprint reality?
    - Is the right answer "we will never run *Node*; we run **JS** via a compile-to-wasm engine (QuickJS
      now; possibly an AOT JS→wasm like Porffor/StarlingMonkey later)"? What do we lose (the npm/native
      ecosystem, perf) and is that acceptable?
13. **Python.** CPython compiles to wasm (Pyodide/`python.wasm` exist). Memory footprint per interpreter
    instance? The C-extension ecosystem (numpy etc. compiled to wasm)? Is per-guest CPython-in-wasm
    viable at our density, or does the interpreter's base memory blow the density budget?
14. **The Luerl contrast — the deep fork.** Luerl is a **Lua VM implemented in Erlang** — Lua guests run
    as *native BEAM-scheduled Erlang code*, no wasm at all, getting BEAM isolation/preemption/density for
    free.
    - For which languages is the **"reimplement the interpreter in Erlang/Elixir" (Luerl model)** the
      better choice vs. our **"compile the real reference implementation to wasm + run in Washy"** model?
    - Trade-offs we see: *Luerl-style* = native BEAM speed, perfect preemptive isolation, no wasm/atomics
      overhead, no atom-table/codegen pressure — **but** you must reimplement the language (huge effort,
      perpetual compatibility drift, one language at a time). *Wasm-style* = run the **real** implementation
      (perfect compatibility) for **any** language with a wasm-targeting compiler, at interpreter/JIT
      speed, but pays the wasm-in-BEAM tax and the codegen/atom walls above.
    - Is there a **hybrid**: a small, hot, common language (Lua, a calculator DSL, a query language) gets
      a Luerl-style native-BEAM implementation, while everything else rides the wasm lane? How would you
      decide the cutover per language?
15. **Memory translation, end to end.** When a guest runs, its memory is spread across: per-process heap
    (interpreter/JIT state), an off-heap atomics linear memory, refc binaries (I/O), persistent_term
    (shared compiled code), and the global atom/code tables (shared, per-compiled-function). Is this the
    right decomposition? Which piece scales worst, and what's the single highest-leverage change to push
    density from "hundreds" to "tens of thousands" of guests per box?

### F. Sanity checks on the whole premise
16. Is "untrusted wasm executed *inside* the BEAM for density + preemptive isolation" sound, or are we
    fighting the VM? Where would an expert expect this to break first under real load — atoms, code
    memory, atomics allocation, GC pauses, scheduler contention, or something we haven't named?
17. What measurements should we take *now* to de-risk this (the specific `:erlang.memory/0` buckets,
    `:erlang.system_info/1` keys, `+M` allocator stats, atom/code counts) so we see the wall coming
    instead of hitting it in production?

---

## 3. What a great answer looks like
A prioritized list of the walls we'll actually hit first (with the order and the approximate thresholds),
the concrete mitigation for each (especially the **atom-table / module-per-function** problem — that's the
one we're most worried about), a clear verdict on the **Luerl-vs-wasm fork** per language class, and the
handful of metrics to instrument today. Correct us where our mental model is wrong.

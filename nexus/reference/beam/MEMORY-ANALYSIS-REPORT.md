# BEAM memory & density — deep-research report (third-party answers to MEMORY-RESEARCH-QUESTIONS.md)

External analysis answering the brief in `MEMORY-RESEARCH-QUESTIONS.md`. Condensed; the verdicts and
thresholds are load-bearing. **Bottom line: the premise is sound, but two self-inflicted walls must be
fixed before scale — the per-function atom-table growth and the persistent_term code cache.**

## 1. ERTS memory topography (where guest state lives, how it's reclaimed)

| Category | Scope | Reclamation | Trigger / lifecycle |
|---|---|---|---|
| Young heap | per-process | Cheney copying GC | stack+heap meet, or `test_heap` exceeds free |
| Old heap | per-process | fullsweep copying GC | after N minors (`fullsweep_after`), or young-GC fails |
| Refc binaries (>64B) | global off-heap | reference counting | `ProcBin` pointers GC'd → refcount 0 (`binary_alloc`) |
| Heap binaries (≤64B) | per-process | copying GC | collected with local terms |
| `:atomics`/`:counters` | global off-heap | magic-ref refcount | freed when the process-heap magic-ref term is GC'd / process dies |
| ETS | global off-heap | manual / owner death | `ets_alloc`; lookups COPY into caller heap |
| `:persistent_term` | global (`literal_alloc`, 1GB super-carrier) | **global GC scan on write/delete** | put/delete forces EVERY process to scan its heap; ref-holders fullsweep (2 at a time) |
| Atom table | global | **never** | persists until node death; hard ceiling default ~1,048,576 |
| Loaded code (BEAM + BeamAsm native) | global (`ll_alloc`) | dual-version purge | 3rd load purges old; running-in-old → killed on hard purge |

## 2. Our `:atomics`-as-linear-memory — verdict: fine, with one caveat

Lifetime is correct: the off-heap array is bound to the magic-ref held in the process dict (`:washy_mem`);
freed on overwrite or process death. No hard per-array cap (OS virtual-address bound). **Caveat: carrier
behavior under churn.** Allocations crossing the singleblock-carrier threshold (`sbct`) go straight to
`mmap`/`munmap` (per-guest syscall overhead at high churn); below it they share multiblock carriers that
**can't return to the OS while any block is live** (fragmentation bloat under churn). Alternatives
(off-heap binary = immutable, wrong; NIF-managed `mmap` resource = enables CoW page-sharing + mmap'd files
but adds native-code risk + yield management). **Keep atomics; tune allocators (§7).**

## 3. The walls, in priority order

### WALL #1 — Atom-table exhaustion (CRITICAL, self-inflicted). 
We mint a unique module-name atom **per compiled function** (`:"washy_asm_N"`, `:"washy_hot_N"`). Atoms
never GC. At thousands of guests × hundreds of hot funcs → exhaust ~1M ceiling → **unrecoverable VM crash**.
`+t` only delays it.
- **Mitigation A (atom pool + recycle): impractical.** 2-version limit; reusing an atom needs
  `check_old_code` + `check_process_code` across ALL processes before `soft_purge` — scanning thousands of
  stacks is heavy; a 3rd load hard-purges and kills processes still in old code. The safe recycle protocol
  exists (check_old_code → check_process_code all pids → force a fully-qualified external call to bump
  in-flight frames to current → soft_purge → load) but is too costly at high frequency.
- **Mitigation B (ONE BEAM module per guest module): RECOMMENDED.** Atom growth O(functions) → O(guest
  modules). Inter-function calls become native-local (no trampoline). Our asm lane compiles ~linearly, so
  a whole-guest-module compile is feasible. **This is the fix.** (bd wb-65ak)
- **Mitigation C (single fixed dispatcher):** zero atom growth but reverts to interpreter — loses the JIT.

### WALL #2 — `:persistent_term` as the code cache (CRITICAL, self-inflicted).
Our compiled-code cache lives in persistent_term keyed per function. **Every put/delete triggers a global
GC scan** forcing ref-holding processes to fullsweep (2 at a time). At thousands of guests → continuous
global heap scans + scheduler stalls. persistent_term is for write-rarely/read-always config, not a
high-cardinality evictable cache. **Fix: ETS, `read_concurrency: true`** — lock-free reads, O(1)
update/delete, no process-GC impact, evictable. (bd wb-4fym)

### WALL #3 — Loaded-code memory + code_server contention.
Each loaded module costs ~10–30 KiB `ll_alloc` baseline (metadata/exports/literals/stackmaps). Thousands
of tiny modules inflate the global export table + literal area and serialize on the single `code_server`
(high-frequency parallel load/purge bottlenecks the node). **Mitigation B (fewer, bigger modules) fixes
this too.**

### WALL #4 — Bignum pressure (tax, not wall).
i32 stays a fixnum; i64 > 60 bits boxes to a heap bignum (header + 1–2 words) → per-iteration alloc in hot
64-bit loops → frequent minor GC. Mitigation (future): map the guest i64 eval stack to off-heap atomics
slots, mutate in place, keep i64 off the process heap. (bd wb-iyh7)

### WALL #5 — Refc-binary leak under I/O.
A busy guest doing off-heap I/O (stdout/VFS/SQLite) generates little heap garbage → rarely GCs → its
`ProcBin` refs to large off-heap binaries never drop to 0 → physical memory grows. **Fix: spawn guest
runners with low `fullsweep_after` (5–10) + manual `:erlang.garbage_collect/1` after heavy I/O bursts.**
(bd wb-iyh7)

## 4. Process density + GC dynamics
Idle process floor ~326 words (~2.6 KiB); realistic idle guest ~8–12 KiB (dict + stack + atomics refs).
Scheduling scales (reduction-based, 2000/timeslice); the bottleneck at density is the **allocator**
(schedulers retain empty carriers rather than returning to OS). Recursion: stack+heap share one block; deep
recursion triggers repeated stack-growth GCs — mitigate with `min_heap_size` at spawn + emit tail calls as
BEAM `call_only` (deallocate-before-call). Frame zero-init (what our JIT does) is correct for GC tracing.

## 5. Future targets — verdicts
- **Node.js / V8 → dead end.** V8 needs dynamic native codegen (W⊕X), OS threads, tens of MB/instance —
  structurally incompatible with a Wasm linear-memory sandbox + our density. **Run JS, not Node:** QuickJS
  (~150–200 KB, runs in 10–64 KB RAM) now; AOT JS→wasm (Porffor) later. Lose: native npm addons + V8 perf.
  Acceptable.
- **Python / CPython → unviable per-guest at density.** 10–25 MB wasm binary, several MB baseline per
  instance, C-extensions need wasm dynamic linking. Thousands of per-guest CPythons exhaust RAM. (Use
  sparingly / shared, not one-per-guest.)
- **Luerl-vs-wasm fork → HYBRID.** Native-interpreter lane (Luerl-style, ~4–8 KB baseline, zero
  codegen/atom/linear-memory pressure, absolute isolation) for **lightweight/domain-specific** guests
  (Lua, calc/expr DSLs, routing rules). Wasm-JIT lane (native speed, universal language support) for
  **system/compiled/heavy** guests (Rust/C/Go/Zig, heavy JS). Decide per language by: hot+small+already-
  implemented → native lane; everything else → wasm.

## 6. Single highest-leverage change for density
Collapse codegen to **one module per guest** (Wall #1/#3) and move the cache to **ETS** (Wall #2). Those
two take us from "hundreds" toward "tens of thousands" of guests/box. Everything else is tuning.

## 7. Telemetry to instrument NOW (with thresholds + remediation)

| Target | API | Danger | Action |
|---|---|---|---|
| Atom table | `system_info(:atom_count)`/`(:atom_limit)` | >85% | stop new compiles; consolidate funcs→one module |
| Loaded modules | `length(:code.all_loaded())` | >100,000 | soft-purge inactive; consolidate |
| Allocator frag | `system_info({:allocator, :eheap_alloc})` | carrier frag >1.2 | `+Mea max`, `+M<S>acul de` |
| Literal carrier | `:erlang.memory(:system)` / PT info | >800 MB (of 1 GB) | `+MIscs` larger |
| Global GC stalls | scheduler/run-queue latency | spikes >50 ms | replace persistent_term → ETS |
| Off-heap binary | `:erlang.memory(:binary)` | >50% RAM | force `garbage_collect/1` on I/O procs |

Boot flags to adopt: `+Mea max` (segregate allocators), `+M<S>acul de` (carrier reuse under churn).

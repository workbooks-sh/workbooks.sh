# externref ABI conversion — full touch-point inventory

**Goal:** convert the Porffor JS-value representation from the dual-slot `[f64 value, i32 type-tag]`
model to a single `externref` (wasm reftype `0x6f`) handle. The BEAM asm lane already moves BEAM
terms as externref values transparently (proven: `/tmp/externref_spike.exs`, 4.01× on property-access
dispatch, 75% time saved). The work is **pure Porffor codegen + a host box/unbox import surface**.

**Constraint (CLAUDE.md non-negotiable #1):** green build at all times → land incrementally behind a
flag (`--externref-values` or similar) that flips to default only once the whole path is converted.

---

## 1. Value allocation / locals
- `compiler/codegen.js:8094` — `func.params = new Array(args.length*2)...` alternating f64/i32 pairs (every arg → 2 slots).
- `compiler/codegen.js:110-112` — indirect-call wrapper: `params.push(valtypeBinary, Valtype.i32)`, dual locals `#i` + `#i#type`, idx stepping by 2.
- `compiler/codegen.js:3478-3501` — **`allocVar()`**: when `type=true` ALWAYS creates two locals: value (`name`, f64/i32) + type (`name#type`, i32).
- `compiler/codegen.js:176` — `#array` parallel dual-local in rest-arg handling.
- `compiler/codegen.js:917` — `localTmp` defaults to valtypeBinary.

## 2. Function signatures
- `compiler/codegen.js:7447` — **DEFAULT** `returns: [valtypeBinary, Valtype.i32]` for every FunctionDeclaration/Expression/Arrow.
- `compiler/codegen.js:123, 153` — indirect wrappers return the pair.
- `compiler/assemble.js:143-163` — `getType(params, returns)` bakes pair arity into the wasm FuncType section (funcs + imports).
- `compiler/assemble.js:186, 197` — import/func sections encode pair-based type indices.
- `compiler/assemble.js:430-438` — `call_indirect` type encoding pushes `valtypeBinary, Valtype.i32`, returns the pair.
- `compiler/codegen.js:2936-2937, 3002` — param-slot indexing assumes pair stride (`i*2` when typedParams).

## 3. Type-tag production / consumption
- `compiler/codegen.js:1851-1877` — `getLastType()` / `setLastType()` / shared i32 `#last_type`.
- `compiler/codegen.js:745, 778, 995, 1008, 1372, 1435, 2449, 2457` — setLastType call sites.
- `compiler/codegen.js:1936, 1951, 2009, 2049, 2114` — getLastType reads (fallback inference).
- `compiler/codegen.js:3302-3465` — **`typeSwitch()`** core type dispatch on TYPES.* (the polymorphism hinge; brTable lives here).
- `compiler/codegen.js:2513, 2629` — getNodeType → typeSwitch (prototype/member dispatch).
- `compiler/codegen.js:6505-6533` — member eval captures property type in `#member_prop_type*` i32 temp.

## 4. Object & member ops
- `compiler/codegen.js:6321-6397` — `generateObject`: pushes `TYPES.object`, value-then-type per property, calls `__Porffor_object_expr_*`.
- `compiler/codegen.js:6451-6700+` — `generateMember`: `__Porffor_object_get`/`_withHash` take obj+key pairs, return a pair.
- `compiler/codegen.js:4566-4580, 6829-6831` — object get/set builtin call sites (all pairs).
- `compiler/builtins/_internal_object.ts:4-19` — object memory layout: `f64 value (8) + u16 type+flags (2)` per entry.
- `compiler/builtins/_internal_object.ts:22-665, 743-859` — `__Porffor_object_hash/writeKey/lookup/readValue/get/set/...` all assume `any` = pair.

## 5. Builtin signatures
- ~**379 of 626** exported builtins take `any` params (≈61% of surface) → re-lower from `.ts` with new signature.
- Hot files: `_internal_object.ts`, `array.ts`, `string.ts`, `object.ts`, `number.ts`, `json.ts`, `promise.ts`, `regexp.ts`.
- Registration: `includeBuiltin(scope, name)` resolves `.index`; callee `.params`/`.returns` already pair-shaped by codegen.

## 6. Elixir asm-lane bridge
- `lib/tiny_lasers/wasm.ex:649-656` — `call_fn` returns stack top; pair-returning funcs give 2-elem result `[value, type]`.
- `lib/tiny_lasers/wasm.ex:2124-2126` — interpreter explicitly handles `[value, type]` pairs (single-value form drops the type).
- `compiler/wrap.js:32-74` — `porfToJSValue({memory,funcs,pages}, value, type)` deserializes pair → JS; becomes `porfToJSValue(externref_handle)`.

## 7. Existing externref support
- `compiler/wasmSpec.js:50-52` — `Reftype = {funcref:0x70, externref:0x6f}` defined, **unused** for values.
- `lib/tiny_lasers/wasm.ex:1259-1306` — `guest_table_*` (get/set/size/grow/fill) + `guest_ref_is_null` exist for funcref; externref table would follow.
- `lib/tiny_lasers/wasm.ex:129-132` — table import parsing reads reftype byte but discards it (no funcref/externref distinction tracked).

### Minimal host-import surface to add
```
__Porffor_box_value   : [valtypeBinary, i32]      -> [externref]   # pair -> handle
__Porffor_unbox_value : [externref]               -> [valtypeBinary, i32]   # handle -> pair
__Porffor_externref_get : [externref, <key pair>] -> [<value>]     # element/2-style property read
```
None defined yet; wire through `lib/tiny_lasers/js/porffor_host.ex` `host_call/1` + the runtime import dispatch.

---

## REALIZATION DECISION (measured 2026-06-30)

Target refined to **objects-as-host-terms**, NOT a full value-ABI rewrite: heap objects live host-side
as BEAM terms; primitives (number/bool) keep the unboxed `[f64, i32]` pair so arithmetic stays fast.

Two realizations measured (`/tmp/handle_bench.exs`, 2M property accesses, real `call_io` lane):

| Realization | Wall | vs true-externref |
|---|---|---|
| True externref (object = externref slot, host `element/2`) | 840ms | 1.00× |
| **i32-handle + host object table** (value slot = i32 handle, host map lookup) | 861ms | **1.03×** |
| (baseline: `[f64,i8]` + 20-branch dispatch) | ~3440ms | 4.1× slower |

**Chosen: i32-handle + host object table.** It captures essentially the full 4× win while keeping the
pair ABI 100% intact — NO externref valtype, NO signature changes, NO 3-slot ABI. The object's "value"
slot holds an i32 handle into a host-resident object table (handle → BEAM map/tuple). This means the
externref valtype plumbing (Stage 1 below) is NOT on the critical path; the build collapses to swapping
the `__Porffor_object_*` builtins + object literal creation to host imports keyed by handle.

### Revised staged path (handle model)
1. **Host object model** (`lib/tiny_lasers/js/porffor_host.ex` + runtime dispatch): a process/ETS-backed
   handle→object table with imports `__Porffor_ho_new() -> i32`, `__Porffor_ho_get(h, key) -> value pair`,
   `__Porffor_ho_set(h, key, value)`, `__Porffor_ho_has`, `__Porffor_ho_keys`. Keys: string/number.
2. **codegen flag** `--host-objects`: `generateObject` (codegen.js:6321) emits `ho_new` + `ho_set`;
   `generateMember` (6451) emits `ho_get`. Object type tag stays `TYPES.object`; value slot = handle.
   Parallel path, default off.
3. **Identity/semantics**: prototype chain, property enumeration order, `in`/`delete`, accessors —
   map onto the host table; defer exotic (Proxy) to the pair-ABI fallback.
4. **Gate**: oracle-match vs pair-ABI objects through `call_io` on the real corpus; then bench warm acorn.

The original externref-valtype staged path below is retained for reference only (superseded by the
handle model unless a future need for true externref values—e.g. GC handoff—reappears).

## Staged conversion path — SUPERSEDED (externref-valtype, for reference)
1. **Spec + assemble:** externref valtype + type indices for externref returns (`wasmSpec.js`, `assemble.js`).
2. **Host imports:** `box_value`/`unbox_value`/`externref_get` in `porffor_host.ex` + runtime dispatch; reuse `:tl_imports` BEAM-term passthrough proven in the spike.
3. **codegen flag:** split `allocVar`, func signature init, call sites on `Prefs.externrefValues`; parallel path, default off.
4. **Builtins:** re-lower `any`-typed builtins to externref signatures (start with `_internal_object.ts`).
5. **Interpreter:** `wasm.ex` 1-result unpack path for externref-returning funcs; `wrap.js` single-handle deserialize.
6. **Cutover:** flip default once the corpus oracle-matches the pair ABI on the real lane.

## Risk notes
- typeSwitch (§3) is the polymorphism hinge — under externref, type reads become host dereferences; measure per-`typeSwitch` overhead vs the 4× dispatch win (net should stay strongly positive per spike, but verify on real corpus, not synthetic).
- Object memory layout (§4) is incompatible between models — needs box/unbox at the boundary during the parallel-path phase.
- Gate every stage on oracle-match through `call_io` (the production lane), never `wasm-tools validate` (it rejects benign Porffor builtin patterns the asm lane runs correctly — see brTable, commit `e7584e1e`).

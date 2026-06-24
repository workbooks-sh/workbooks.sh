# BEAM assembly reference — the low-rung target for Washy

**Why this folder exists.** The end-state is **Washy subsumes wasmtime**: untrusted wasm runs in the
BEAM (pure Elixir, no NIF, no subprocess), densely and isolated, *fast enough* by compiling wasm →
**native via BeamAsm**. The lever for speed + control is to **emit BEAM assembly directly** (not
Erlang abstract forms), so we skip the Erlang frontend + the superlinear `beam_ssa_opt` pass entirely.
This folder is the ground-truth so we align on the exact instruction set + assembler semantics for our
OTP, and keep aligning every loop.

**Our target: OTP 28.3.2 · erts-16.2.1 · compiler-9.0.4 · emu_flavor = `jit` (BeamAsm active, arm64 on Fly).**

## The validated API (spike: 2026-06-24 — proven working)

```elixir
# 1. emit BEAM assembly as text (the {function,...}/opcode-tuple format — see sample-erlc-S.S)
asm = """
{module, wbspike}.
{exports, [{add,2}]}.
{attributes, []}.
{labels, 3}.
{function, add, 2, 2}.
  {label,1}.
    {func_info,{atom,wbspike},{atom,add},2}.
  {label,2}.
    {gc_bif,'+',{f,0},2,[{x,0},{x,1}],{x,0}}.
    return.
"""
File.write!(path, asm)
# 2. assemble -> bytecode (skips the whole SSA pipeline by construction)
{:ok, mod, bin} = :compile.file(~c"#{path}", [:from_asm, :binary])
# 3. load -> BeamAsm JITs it to native at load time
{:module, ^mod} = :code.load_binary(mod, ~c"#{path}", bin)
mod.add(3, 4)  #=> 7, running as native machine code
```

**Measured (800-op straight-line fn):** abstract-forms compile = 36.4ms · **from_asm = 4.7ms (7.8×
faster)** — and from_asm CANNOT hit the ssa_opt blowup because it never runs that pass. The bigger the
function, the wider the gap (the forms path is superlinear; from_asm is ~linear).

Notes from the spike:
- `erlc -S file.erl` emits the canonical `.S` for any Erlang source — the **format oracle**. The
  `{tr,{x,0},{t_number,...}}` register wrappers in real output are *type-optimizer annotations*; a
  hand-emitted lowering uses plain `{x,0}`/`{y,0}`/`{integer,N}` etc.
- In-memory alternative to a temp `.S` file: parse the asm terms and call the asm passes directly; the
  file path is simplest to start. (`beam_asm.erl` is the assembler module.)
- `x` regs = volatile args/temps; `y` regs = stack slots (need `allocate`/`deallocate`); `{f,L}` =
  failure/jump label; `gc_bif` = a guard BIF that may GC. See `sample-erlc-S.S` for `loop/1` (a real
  call + stack frame).

## What's here

### `otp-src/` — ground truth for OUR exact toolchain
- `genop.tab` — the **generic opcode table** (number ↔ name ↔ arity for every BEAM op). The canonical
  opcode list.
- `ops.tab` (emu) + `ops-jit-x86.tab` + `ops-jit-arm.tab` — the **specialization/transform rules** the
  loader/JIT use to turn generic ops into specialized ones (and, for jit/, into native). `ops-jit-arm`
  is our Fly target.
- `beam_asm.erl` — **the assembler**: asm tuples → `.beam` bytecode. The thing `from_asm` drives. Read
  this to know exactly which tuple shapes are accepted.
- `beam_disasm.erl` — the **disassembler**: `.beam` → asm tuples. Use it to learn-by-example (compile
  any Erlang, disassemble, copy the shape).
- `beam_validator.erl` — the **bytecode verifier**. Our emitted asm must pass this (register liveness,
  type safety). When `load_binary` rejects our code, the reason comes from here — read it.
- `beam_ssa.erl`, `beam_ssa_codegen.erl` — the SSA IR + codegen we are *bypassing*; kept to understand
  what the forms path does that we're skipping (and to crib correct codegen patterns).
- `compile.erl` — entry point; shows how `from_asm` / `from_core` / `binary` options route.

### `beam-book/` — prose semantics (The BEAM Book, happi/theBeamBook)
- `beam_instructions.asciidoc` — instruction set walkthrough.
- `ops.asciidoc` — how generic ops are specialized/loaded.
- `beam_loader.asciidoc` — loading + how BeamAsm turns bytecode into native.
- `calls.asciidoc` — call/return, stack frames, tail calls (maps directly to wasm `call`/`return`/loops).
- `scheduling.asciidoc` — reductions = our fuel/preemption lever; why this beats a wasmtime subprocess
  on few-core Fly boxes.
- `type_system.asciidoc` — the tagged-term representation (how integers/floats/binaries are boxed) —
  needed to emit correct arithmetic + the wasm linear-memory-as-binary model.

### `sample-erlc-S.S` — a real `erlc -S` dump (add/2 + a recursive loop/1) = the format oracle.

## The ladder (where we generate, lowest = fastest compile + most control)
1. **Erlang Abstract Format** — where Washy is today (`Transpile` → `:compile.forms`). Convenient, but
   drags every op through the full compiler incl. ssa_opt (we run `no_ssa_opt` to survive).
2. **Core Erlang** (`from_core`) — skips the frontend. Cheap intermediate win.
3. **BEAM assembly** (`from_asm`, this folder) — **the prize.** wasm opcodes → BEAM asm opcodes is a
   near-1:1 transliteration; ~linear compile; BeamAsm still gives native. This is "what wasmtime does
   (IR→target asm→native), delivered inside the BEAM."

## Keep aligning
When emitting a new op: find it in `genop.tab` (exists? arity?), confirm the accepted tuple shape in
`beam_asm.erl`, check `beam_validator.erl` for the constraints, and verify against a `erlc -S` /
`beam_disasm` dump of equivalent Erlang. Never guess a tuple shape — disassemble a real example.

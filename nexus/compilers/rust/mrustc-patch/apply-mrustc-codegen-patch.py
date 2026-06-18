#!/usr/bin/env python3
"""Idempotently patch mrustc's C backend to lower the `llvm.wasm.*` intrinsics.

mrustc's `src/trans/codegen_c.cpp::emit_function_ext` has a catch-all for any
unhandled `extern "llvm"` item that emits `assert(!"Extern LLVM: <name>"); abort();`.
That aborts on:
  * the wasm FUTEX intrinsics `llvm.wasm.memory.atomic.wait32/wait64/notify`
    (rayon-core's Condvar/LockLatch worker park/wake — the ONLY rayon blocker), and
  * ~40 `llvm.wasm.*` SIMD (v128) intrinsics (bitmask, swizzle, narrow, *_all_true,
    extadd_pairwise, q15mulr, relaxed_madd/nmadd/laneselect/swizzle).

This inserts `else if` branches (held in `wasm-intrinsics-block.cpp.txt`) immediately
BEFORE the catch-all, lowering each to the matching clang `__builtin_wasm_*` builtin
(our C backend is clang.wasm targeting wasm32, so the builtins exist). The futex pair
maps scalar int/ptr args 1:1; the SIMD branches bit-cast v128 (a 16-byte struct in
mrustc) through local clang ext-vector typedefs.

User-authorized mrustc-source patch (the usual "no mrustc fork" stance is crossed
deliberately, kept surgical). The mrustc tree is gitignored, so this script is the
durable, reproducible record — wired into provision-rust.sh BEFORE the mrustc build.

Idempotent: no-op if the marker comment is already present.
Usage: apply-mrustc-codegen-patch.py <path to mrustc/src/trans/codegen_c.cpp>
"""
import sys, pathlib

CODEGEN = pathlib.Path(sys.argv[1])
BLOCK = (pathlib.Path(__file__).parent / "wasm-intrinsics-block.cpp.txt").read_text()
MARKER = "Workbooks: wasm32 LLVM intrinsics"

src = CODEGEN.read_text()
if MARKER in src:
    print("[mrustc-codegen-patch] codegen_c.cpp already patched — skip", file=sys.stderr)
    sys.exit(0)

# Anchor: the catch-all `else` block (the only `"Extern LLVM: "` site). Insert our
# block immediately before it. We match the exact pristine catch-all text so a layout
# change upstream fails loudly rather than mis-inserting.
ANCHOR = (
    '                else {\n'
    '                    // TODO: Hand off to compiler-specific intrinsics\n'
    '                    //MIR_TODO(*m_mir_res, "LLVM extern linkage: " << item.m_linkage.name);\n'
    '                    m_of << "\\tassert(!\\"Extern LLVM: " << item.m_linkage.name << "\\"); abort();\\n";\n'
    '                }\n'
)
if src.count(ANCHOR) != 1:
    print(f"[mrustc-codegen-patch] FAILED: expected exactly 1 catch-all anchor, found "
          f"{src.count(ANCHOR)} (mrustc codegen_c.cpp layout changed?)", file=sys.stderr)
    sys.exit(1)

block = BLOCK
if not block.endswith("\n"):
    block += "\n"
src = src.replace(ANCHOR, block + ANCHOR, 1)
CODEGEN.write_text(src)
print("[mrustc-codegen-patch] codegen_c.cpp patched (wasm futex + SIMD intrinsics lowered)",
      file=sys.stderr)

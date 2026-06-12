# WASM dependency conversion — decision table

**Invariant: no native execution on a deployed runtime.** Every dependency
becomes a capability-gated WASM command. Never install a native toolchain
(node, python, cargo) into a runtime image, and never shell out to real OS bash.

## Classify each dependency

| Dep kind | Lane | Commands | Notes |
|---|---|---|---|
| Interpreted (qjs, python, ruby, lua, yaegi) | already in-sandbox | `wbx toolkit build palette [<runtime>]`, then invoke | no compile step |
| Compiled (C, Zig, Rust) | compiler-in-WASM | `wb-rt compiler build <lang>` → `wb-rt compiler run` | recipes in `runtime/compilers/<lang>/` |
| npm package | PackageManager | resolve → fetch → bundle → WASM | Node shims provided |
| Rust crate | PackageManager | resolve → build via the Rust lane | crates.io enablement is active frontier |

## The flow

1. **List** every dep the workbook imports or shells to.
2. **Classify** each row above.
3. **Convert** through its lane → a capability-gated WASM command.
4. **If a dep cannot convert:** FILE an issue describing the gap. Do **not**
   fake it, stub it with native exec, or quietly drop the feature. Mislabeling a
   missing capability as "gated" instead of filing it is the canonical failure.

## Capabilities are brokered, never ambient

A WASM command only gets filesystem / network / time through **Dock imports**
granted by policy. Capabilities flow **down by grant, not by inheritance**.
Don't assume ambient access; request the capability explicitly.

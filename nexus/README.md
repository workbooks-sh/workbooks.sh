# nexus

The runtime, **rebuilt clean** around the new authoring model — not slimmed from the old one.

We changed the entire authoring structure (literate `.work` → `resource`/`record`/WIT/Ash),
which means the old runtime's data/capability/agent layers were built for a world that no
longer exists. So we start fresh and keep only what's genuinely ours and genuinely hard.

## What we keep (the moat)

- **The compilers** — multi-language source → wasm (rust/zig/c/js via mrustc et al.). The one
  thing we built from scratch that took real time. `nexus` *reuses* `runtime/host/compilers/*`
  (referenced, not rewritten).

## What we DON'T carry over

- **VFS-as-store** — data is **Ash** now (server-authoritative), not a per-instance SQLite file.
- **Policy** — capabilities are the **Dock registry + WIT grants** now.
- **command_registry / pallet** — running a wasm tool is **wasmex**'s job; we don't think we need
  the old registry layer. Revisit only if something real needs it.
- **Old agent harness** — agents are authored as `.work` units now; they compile/run through the
  standard unit lane, not a bespoke harness.
- **Old telemetry / git / brokers** — rebuilt thin against the new model, or dropped.

## The layers (thin shells over standards)

```
author   →  Literate     parse a .work file into ordered nodes (md + Elixir AST)
            Resource      a resource/record's declared fields  (the shape)
contract →  Wit          generate the WIT world from the shape + signatures
            Dock         the one capability registry (caps → WIT import + impl)
data     →  (Ash)        resources ARE Ash resources — the database, not ours
run      →  Unit         server units → native BEAM modules
            Sandbox      client/foreign units → wasm components, run on wasmex
compile  →  Compile      orchestrate: .work → {Ash resources, BEAM modules, wasm components, WIT}
weave    →  Weave        a workbook (folder of .work) → one self-contained .html
```

Everything not on that list is suspect. Build green, one shell at a time. Publishing is a
separate app.

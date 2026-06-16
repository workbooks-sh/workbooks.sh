# Dock SDK — ergonomic capability bindings for toolkit authors

*2026-06-08*

# What this is

  The Dock SDK is the published, author-facing face of the Dock membrane (see
  [host-vs-loaded-boundary](host-vs-loaded-boundary): the Dock is the seam between deploy-fixed host and
  runtime-loaded toolkits). It turns the raw, stringly WIT imports into idiomatic
  per-language calls so a `component`/`kernel` toolkit author never hand-marshals
  JSON or hand-builds output strings.

  Today an author writes (engine-llm-probe/src/lib.rs — the BEFORE):
```rust
  let reply = bindings::llm_complete(&format!("In 5 words: {}", input));
  format!("{{\"asked\":\"{}\",\"llm\":\"{}\"}}", input, reply.replace('"', "'"))
```

  Stringly call, manual JSON, a quote-escaping hack that corrupts data. The SDK
  (the AFTER):
```rust
  let reply = dock::llm::ask(format!("In 5 words: {input}"))?;
  dock::out(json!({ "asked": input, "llm": reply }))
```

# The cap-scoping rule (load-bearing — do not break it)

  A component that imports a WIT function its Policy profile does not grant
  FAILS TO INSTANTIATE (capability enforcement by construction,
  instance/imports.ex). Therefore the SDK is **cap-scoped**: an author pulls in
  exactly the caps their granted profile allows, and no more.

  - In Rust: an EXPLICIT cap list on the macro — `dock::bind!(bindings, llm, vfs)`
    emits the llm + vfs wrappers and NOTHING else. (Cargo features do NOT work for
    this: the macro expands in the caller's crate, whose features differ from
    dock's, so a feature on the dock dependency was invisible — wb-pkh.2/.12.)
  - The enabled feature set MUST match the component's declared WIT subset world
    and the toolkit manifest's `#+CAPS`. `wb toolkit verify` cross-checks the
    declared #+CAPS ⊆ granted profile (the cap list must match the WIT world).

  Corollary (resolves an apparent "drift"): the base `engine.wit` world stays a
  MINIMAL common set. llm-complete is bound in imports.ex + gated by the `llm`
  cap but is intentionally NOT in the base world — richer caps live in
  per-component SUBSET worlds (engine-llm-probe declares its own). Do NOT "fix"
  this by fattening the base world; that would force every base component to be
  granted every cap. Subset worlds are the design.

# The capability surface (v1 — caps that exist in the host today)

| cap | Rust | returns | host |
| --- | --- | --- | --- |
| (always) | `dock::session()` | `Session` | session-info |
| `vfs` | `dock::vfs::query::<T>(sql)` | `Vec<T>` | vfs-query |
| `commands` | `dock::command::run(name, input, args)` | `String` | run-command |
| `llm` | `dock::llm::ask(prompt)` | `String` | llm-complete |
| `browse` | `dock::browse::fetch(url)` | `Page` | browse-fetch |
| `parallel` | `dock::parallel::map(name, inputs)` | `Vec<Result<String>>` | run-command-many |

  All fallible calls return `dock::Result<_>` (a host-error string becomes
  `Err(DockError)`, not a silently-corrupt value). Output:
  - `dock::out(impl Serialize) -> String` — the clean `run` return builder.
  - `dock::rows::<T>(json) / dock::page(json)` — marshalling helpers if you hold
    a raw Dock string (e.g. from a hand-declared import).

# Staged caps (host side not yet wired — wb-rhs.5)

  Still staged behind a `compile_error!` until its host side lands:
  - `frames` → `dock::frames::{borrow, commit}` the shared-frame arena: hand a
    frame between kernels by offset, not by re-copying across the NIF boundary.

  (`parallel` used to be here; it is now LIVE — the host binds run-command-many →
  Workbooks.Fabric, see the capability surface above.)

# JS counterpart (jco-authored components)

  Same surface, idiomatic JS; the cap-scoping is the imported world, not a
  feature flag (jco componentize targets a WIT world directly):
```js
  import { llm, out } from "dock";        // only the caps your world imports resolve
  export function run(input) {
    const reply = llm.ask(`In 5 words: ${input}`);
    return out({ asked: input, llm: reply });
  }
```

  `out()`, `rows()`, `page()` are pure JSON helpers (no imports); =llm/vfs/
  browse/command= are thin wrappers over the generated jco bindings.

# What v1 ships (this issue)

  - `runtime/sdk/rust/dock` — the Rust crate: `Session`/`Page` types, `out`,
    `rows`, `page`, `DockError`/`Result`, and the bind!(bindings, <caps>) cap-list macro
    (llm/vfs/browse/command/parallel live; frames errors as not-yet-available).
  - This spec.
  Deferred to follow-ups: the JS package build, the feature↔WIT-subset codegen
  glue (today the author declares the WIT subset by hand + enables matching
  features; `wb toolkit verify` checks agreement), and dogfooding the SDK back
  into the engine-*-probe example fixtures.

# See also

  - TOOLKIT-MANIFEST.md §CAPS — the manifest-level cap declaration.
  - host/instance/imports.ex — the host bindings the SDK wraps.
  - wit/engine.wit — the base world; subset worlds live per-component.

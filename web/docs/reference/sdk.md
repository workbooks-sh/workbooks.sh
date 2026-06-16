
# Dock SDK API

> The Rust and JS binding surface.

The cap-scoped bindings, by capability. List the caps your component imports in
`dock::bind!` (Rust) or import them from the world (JS).

| call (Rust) | returns |
| --- | --- |
| `dock::llm::ask(prompt)` | `Result<String>` |
| `dock::vfs::query::<T>(sql)` | `Result<Vec<T>>` |
| `dock::browse::fetch(url)` | `Result<Page>` |
| `dock::command::run(name, in, args)` | `Result<String>` |
| `dock::parallel::map(name, inputs)` | `Result<Vec<Result>>` |
| `dock::out(value)` | `String` (the run return) |

Every fallible call lifts a host error into `Err`. Output is one call: `dock::out`.
See [The Dock SDK](../build/dock-sdk.md) for the authoring flow.

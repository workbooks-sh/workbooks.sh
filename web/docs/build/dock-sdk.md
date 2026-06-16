
# The Dock SDK

> Ergonomic, cap-scoped bindings so a toolkit reaches the host without hand-marshalling.

The Dock's raw imports are stringly. The SDK turns them into idiomatic, typed,
cap-scoped calls so you never hand-build JSON or parse a result string. There's a
Rust crate and a JS module.

In Rust, you list the exact capabilities your component imports — that list **is**
the cap-scoping (it must match your WIT world and your granted `#+CAPS`):

```rust
dock::bind!(bindings, llm, vfs, parallel);

let reply = dock::llm::ask("In five words: what is a toolkit?")?;
let rows: Vec<Row> = dock::vfs::query("select * from items")?;
let outs = dock::parallel::map("resize", &frames)?;   // fan across isolated instances
dock::out(json!({ "reply": reply }))
```

Every fallible call returns a `Result` — a host error becomes an `Err`, never a
silently-corrupt value. Output is one call: `dock::out(value)` replaces hand-rolled
JSON.

In JS, the same surface over jco-generated bindings:

```js
import { bind, out } from "dock";
const dock = bind(imports);          // only the caps your world imports resolve
const reply = dock.llm.ask("...");
return out({ reply });
```

- The capabilities themselves: [The Dock & capabilities](../concepts/the-dock.md)
- Full API: [Dock SDK API](../reference/sdk.md)

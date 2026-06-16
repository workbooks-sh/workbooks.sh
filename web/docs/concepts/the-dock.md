
# The Dock & capabilities

> The typed, capability-gated surface a toolkit uses to reach the host.

WASM has no ambient authority — no syscalls, no sockets, no filesystem. When a
toolkit needs to do something it can't do alone, it asks the host through *the
Dock*: a typed capability surface where each power is an explicit import.

A toolkit declares the capabilities it needs in its manifest:

```org
#+CAPS: vfs llm browse
```

The host provides **only** the granted capabilities. A toolkit that imports a
capability its profile doesn't grant simply fails to instantiate — enforcement is
by construction, not by runtime check.

## The capabilities

| cap | what it grants |
| --- | --- |
| `vfs` | a sandboxed SQLite store (no host filesystem) |
| `commands` | call another registered command (composition) |
| `llm` | a model completion (the host holds the key) |
| `browse` | fetch + extract a URL (the host opens the socket) |
| `net` | gated outbound HTTP |
| `parallel` | fan work across isolated instances (the fabric) |

The pattern that makes this safe: *the host holds the credential and owns the
egress*. A toolkit that calls `browse` never sees the key and never opens a
socket — it calls the capability, and the host does the work behind it.

- Author against the Dock: [The Dock SDK](../build/dock-sdk.md)
- Full list: [Dock capabilities](../reference/caps.md)

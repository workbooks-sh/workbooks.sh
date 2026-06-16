
# Pick a shape

> Choose the right #+EXEC for what you're building.

Choose by how the thing is **called**, not by language.

- Reading stdin, writing stdout — a filter, parser, formatter? → [=command=](../concepts/exec-shapes.md)
- A typed API the host or another component calls in-process? → `component`
- A `bytes → bytes` transform run in a tight loop (frames, samples)? → `kernel`
- A multi-step procedure with no compiled binary? → `task`
- An external system you want to query? → `federation`
- Something WASM genuinely can't do (native threads, GPU)? → `posix`

When unsure, start with `command` — it's the default, the simplest, and the most
portable. You can always promote to a richer shape later.

```org
#+TOOLKIT:    my-tool
#+EXEC:       command
#+TRUST:      first-party
#+BUILD_LANG: rust
#+BUILD_SRC:  path:src
```

- The shapes in depth: [The six shapes](../concepts/exec-shapes.md)
- Reach the host: [The Dock SDK](dock-sdk.md)

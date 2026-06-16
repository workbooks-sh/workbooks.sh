
# Self-authoring & hot-swap

> An agent can write, build, register, run, and hot-swap a toolkit inside its own container.

The runtime's compiler is itself WASM, registration is dynamic, and an agent has a
shell — so an agent can **author a toolkit for itself, mid-session**, entirely inside
its own sandbox. No native toolchain, no host escape.

```bash
# the agent writes source, then:
wb toolkit build-inline mytool zig ./mytool.zig    # compile in-sandbox → register
run-command mytool < input                          # use it immediately
```

The build is content-addressed, so rebuilding the same source is a cache hit. A
self-built toolkit is capped by the session's profile exactly like any other —
authoring never widens what it's allowed to do.

**Hot-swap** is built in: rebuild under the same name and the new hash replaces the
binding live, no restart. Calls in flight finish on the old bytes; new calls hit
the new ones.

When a session tool proves its worth, **promote** it to a durable, source-owned
workspace toolkit that survives the session and can be packaged:

```bash
wb toolkit promote mytool zig ./mytool.zig
```

- Make it durable + shippable: [Package & sign](../distribute/package.md)


# Your first toolkit

> Build, run, promote, and ship a real sandboxed toolkit in about ten minutes.

In ten minutes you'll write a toolkit, build it to WASM **inside the sandbox**, run
it, make it durable, and ship it. You need the `wb` CLI ([install it here](install.md)) and
nothing else — no compiler, no toolchain on your machine.

## 1 · Write something

A toolkit can be written in JS, C, Zig, Rust, or Go. Start with the smallest
useful shape: a `command` — argv + stdin in, stdout out. Here's a reverser in JS:

```js
// reverse.js — read all of stdin, write it back reversed
const chunks = [];
const buf = new Uint8Array(65536);
let n;
while ((n = Javy.IO.readSync(0, buf)) > 0) chunks.push(buf.slice(0, n));
const all = chunks.reduce((a, c) => a + new TextDecoder().decode(c), "").trim();
Javy.IO.writeSync(1, new TextEncoder().encode([...all].reverse().join("")));
```

## 2 · Build it — in the sandbox

```bash
wb toolkit build-inline rev js ./reverse.js
```

The runtime compiled your source to WASM **without a toolchain on your machine** —
the compiler is itself WASM, running in the sandbox. The result is
content-addressed (its filename is its hash) and registered under the name `rev`.

## 3 · Run it

```bash
run-command rev <<< "hello world"
# → dlrow olleh
```

That's the universal calling convention: `run-command <name>`, argv + stdin →
stdout. An agent calls it this way over bash; a workbook's HTML calls it through
the Dock; a workflow orchestrates it. Same toolkit, every caller.

## 4 · Change it, live

Edit `reverse.js` and rebuild under the same name. The new build gets a new hash
and replaces the old binding **with no restart** — calls already in flight finish on
the old bytes, new calls hit the new ones.

```bash
wb toolkit build-inline rev js ./reverse.js   # hot-swapped in place
```

## 5 · Make it durable

So far `rev` lives in this session. **Promote** it to a real workspace toolkit — a
manifest plus your source — so it survives, rebuilds deterministically, and can be
packaged:

```bash
wb toolkit promote rev js ./reverse.js
# → workspace toolkit `rev`: manifest.org + src + skills, source-owned
```

## 6 · Ship it

A toolkit **is** a workbook. Pack it, and anyone can install it by hash — the hash
is the supply-chain gate, so a tampered bundle is rejected before anything runs.

```bash
wb pack rev rev.wbundle           # one portable .wbundle (HTML + the wasm)
# on another machine:
wb install rev.wbundle            # verifies + registers; now `run-command rev` works
```

## What you just did

You authored a capability, built it without a toolchain, ran it, hot-swapped it,
made it durable, and shipped it — all as plain artifacts, sandboxed end to end.

A `command` is the simplest shape. The same flow scales up: a typed [=component=](../concepts/exec-shapes.md),
a `bytes → bytes` [=kernel=](../run/fabric.md) looped per-frame by the render fabric, or a [=federation=](../distribute/federation.md)
data source. And when a toolkit needs to reach the host — storage, a model, the
network — it asks through [the Dock](../concepts/the-dock.md).

- Understand what you built → [What is a toolkit](../concepts/what-is-a-toolkit.md)
- Reach the host → [The Dock SDK](../build/dock-sdk.md)
- Go deeper on shapes → [The six shapes](../concepts/exec-shapes.md)

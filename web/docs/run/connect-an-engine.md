
# Connect the CLI to a runtime engine

> Point wbx at a running runtime — local discovery by default, or a remote engine via one env var.

Engine-backed verbs (`compile`, `workflow`, `agent`, `toolkit push`, `telemetry`, …)
talk to a running runtime over RCP — a small JSON-over-HTTP+WS connect/auth/transport
floor. The goal here: get `wbx` pointed at the right engine.

There are two paths. Local discovery is automatic; a remote engine is one env var.

## Local engine (default — zero config)

By default the CLI discovers a LOCAL runtime and connects to
`127.0.0.1` on the discovered port with the discovered token. You don't configure
anything — stand the engine up and engine-backed verbs just work.

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/io.rs:118
- **SRC:** cli/src/io.rs#http

1. **Stand up / converge the engine.** `wbx deploy local` brings a runtime up in a
   container (docker | podman | krunvm). See [Deploy a runtime](../deploy/ship-to-the-internet.md).
- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:48

2. **Verify the connection.** Bare `wbx` (or `wbx info`) prints an environment +
   engine health report — state, URL, workspace. Agents get JSON with `--json`.
- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/commands.rs:272

## Remote engine (one env var)

To talk to an engine elsewhere, set `WBX_ENGINE_URL` (the canonical prefix; legacy
`WB_ENGINE_URL` also works). This **overrides** local discovery — the discovery file
only knows about local engines. Add `WBX_ENGINE_TOKEN` for the bearer credential.

```sh
export WBX_ENGINE_URL=https://engine.example.com
export WBX_ENGINE_TOKEN=…              # optional bearer
wbx info                               # confirm it points at the remote
```

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/io.rs:113
- **SRC:** cli/src/io.rs#http

## Talk to it directly

For ad-hoc RCP calls there's a raw escape hatch: `wbx rt status`, `wbx rt get <path>`,
`wbx rt post <path> [body]`. Useful for poking the runtime without an engine-backed
verb in front of it.

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/main.rs:126
- **SRC:** cli/src/main.rs#Rt

## Why RCP

RCP is "LSP, but for runtimes" — one versioned contract any client (desktop, web,
a raw `.html`, mobile) implements to DISCOVER, AUTHENTICATE to, and TALK to any
runtime. The connection logic lives in the contract, not the client.

- **MATURITY:** partial
- **EVIDENCE:** runtime/docs/RUNTIME-CONNECT-PROTOCOL.org:1
- **CAVEAT:** RCP is the named contract (status: draft); discovery + remote override ship today, the full multi-client spec is still being lifted out of the desktop app's hand-wired bridge.

- Distribute compute across a connected engine: [The fabric](fabric.md)
- Invoke toolkits on the engine: [Invoking a toolkit](invoke.md)

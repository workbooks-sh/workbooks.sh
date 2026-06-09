# Platform model — one Host, many targets

> The frontend is one codebase. It runs as a desktop app, a web page, or a
> mobile app with no forks — the difference is **configuration**, not code.

## One contract: the Host (the Dock)

The UI talks to exactly one thing — a single capability surface:

```
UI  →  host.call(capability, args)        // request/response
UI  →  host.stream(capability, args)      // streams: chat tokens, telemetry, watches
```

Capabilities are namespaced verbs: `fs.read`, `keychain.get`, `store.set`,
`agent.run`, `chat.stream`, `weave`, … The UI never knows *where* a capability
is fulfilled. There is no second "runtime contract" the UI manages — see below.

This is the membrane already in the project's mental model (host vs loaded; the
Dock). Concretely it is the existing Tauri `invoke(cmd, args)` seam, generalized.

## Behind the Host: providers + a routing config

The Host is a **router**. Every capability is served by one **provider**:

- `local`   — OS via Tauri (desktop/mobile) or browser-native APIs (web)
- `runtime` — a server over **RCP** (HTTP + WS); see `wb-uxn`
- `kernel`  — the bundled WASM engine (`oql.wasm`), in-process, offline

A **target is a routing config** mapping capability → provider. It is the only
thing that differs between desktop / web / mobile:

| Capability group          | Desktop            | Web page              | Mobile          |
|---------------------------|--------------------|-----------------------|-----------------|
| fs / window / terminal    | local (OS)         | local (browser) / n.a | local           |
| keychain / secrets        | local (OS)         | runtime / WebCrypto   | local           |
| agent / chat / data / sync| runtime            | runtime               | runtime         |
| weave / validate / outline| kernel             | kernel                | kernel          |

The runtime is **separate and shared**: one server can back many apps + pages.
A published page and a desktop app carry the same RCP endpoint and behave the
same — that is the point of a standalone runtime.

### The one honest caveat

One contract does **not** mean every capability exists everywhere. Web has no
PTY; the Host reports that capability *unavailable* and the UI degrades (it
already does graceful-offline today). Availability varies by config; the
contract stays single.

## Build / packaging

One frontend build. Packaging is just a wrapper:

- **Desktop / mobile** — Tauri (the OS webview) wraps the static frontend.
- **Web** — serve the static frontend.

Same compile; swap the **host routing config** + the **runtime endpoint**.
"Publish anywhere" = choose a preset + a runtime URL. One config object, which
an agent can author — the workbook-format promise applied to whole apps.

## Where this lives in code

- **Host surface** — `$lib/platform/` (the `invoke`-style seam). `webHost.ts`
  is the browser preview host today: a router whose `local` and `runtime`
  providers are both mocked with seed data. It is the seed of the real WebHost.
- **`local` provider (desktop)** — the Rust `#[tauri::command]` set in
  `src-tauri/`.
- **`runtime` provider** — `$lib/engine-api/gen` (HTTP) + `ws.svelte.ts` (WS).
  Today these are called directly from the UI; unifying them behind the Host
  removes the second call path (less code, one contract).
- **`kernel` provider** — `kernel.ts` over the embedded `oql.wasm`.

## Decisions / status

1. **Contract A vs B → collapsed into one Host with provider routing.** (this doc)
2. **Host surface shape:** keep the implicit `invoke`-command list as the
   contract for now + adapters; formalize as a typed `Host` interface (or a WIT
   component, since we are component-model native) once it stabilizes.
3. **Runtime connection (RCP, `wb-uxn`):** generalize the desktop's local
   discovery file into a runtime-endpoint config (baked default + runtime
   override) + pluggable auth.
4. **Now:** browser preview running off `webHost.ts` so we can iterate the UI.

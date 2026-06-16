# The Host / Dock seam

The one contract a runtime change must respect. Full canon:
`desktop/docs/platform-model.md` (epic `wb-lk6`); runtime connect over RCP is
`wb-uxn`. Read the source doc — this is the working summary.

## One contract: the Host (the Dock)

The UI talks to exactly ONE capability surface:

```
host.call(capability, args)     // request/response
host.stream(capability, args)   // streams: chat tokens, telemetry, watches
```

Capabilities are namespaced verbs — `fs.read`, `keychain.get`, `store.set`,
`agent.run`, `chat.stream`, `weave`, `validate`, … The UI never knows *where* a
capability is fulfilled. **There is no second "runtime contract" the UI
manages.** This is the existing Tauri `invoke(cmd, args)` seam, generalized — the
membrane in the project's mental model (host vs loaded; the Dock).

## Behind the Host: providers + a routing config

The Host is a **router**. Every capability is served by one **provider**:

- `local`   — OS via Tauri (desktop/mobile) or browser-native APIs (web)
- `runtime` — the shared server over **RCP** (HTTP + WS) — `runtime/host/**`
- `kernel`  — the bundled WASM engine (`oql.wasm`), in-process, offline

A **target (desktop / web / mobile) is a routing config** mapping capability →
provider. It is the ONLY thing that differs between targets. Do NOT fork code
per target, and do NOT try to compile the OS/Tauri layer to WASM — swap the
provider behind the one Host instead.

The runtime is **separate and shared**: one server backs many apps + pages.

| Capability group           | Desktop      | Web            | Mobile |
|----------------------------|--------------|----------------|--------|
| fs / window / terminal     | local (OS)   | local / n.a.   | local  |
| keychain / secrets         | local (OS)   | runtime/WebCrypto | local |
| agent / chat / data / sync | runtime      | runtime        | runtime|
| weave / validate / outline | kernel       | kernel         | kernel |

One contract does **not** mean every capability exists everywhere. Web has no
PTY; the Host reports that capability *unavailable* and the UI degrades
gracefully. Availability varies by config; the contract stays single.

## Invariants a runtime change must NOT break

- **One Host.** Never reintroduce a second runtime contract the UI manages.
- **HOST vs LOADED.** Engine code (`runtime/host/**`) is fixed at deploy time,
  changed only by a new image. Loaded artifacts (workbooks, toolkits, agent
  defs, workflow/lifecycle specs, boards) hot-swap on a live engine.
  Self-modifying systems edit LOADED, never HOST.
- **No native execution on a deployed runtime.** All compute runs as
  WebAssembly on wasmtime. Don't install language toolchains (node, python,
  cargo) into runtime images; convert the capability through a compiler lane.
- **Dock imports are brokered, not ambient.** Filesystem/network/time arrive as
  host-brokered imports granted by policy — never inherited. BEAM-offload (a
  capability running on the BEAM instead of in WASM) is the LAST resort, only
  for what WASM genuinely can't do (network, threads).
- **Two HTTP planes never blend.** Public content plane = anonymous, GET-only.
  Control plane = bearer-authed, owns every write. Never add a write to public.
- **Agent and workflow are PEER engines**, not toolkit EXEC shapes.

## Where it lives in code

- Host surface — the frontend's `$lib/platform/` (`invoke`-style seam);
  `webHost.ts` is the browser-preview host (mocked providers).
- `runtime` provider — `runtime/host/**` (the Elixir/BEAM engine). Canonical;
  the desktop frontend re-points onto it, never the reverse
  (`desktop/ASSESSMENT.md`).
- `kernel` provider — `oql.wasm`, in-process.

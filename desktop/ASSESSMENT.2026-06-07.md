# Workbooks Desktop — Promise vs. Delivery Assessment

_Audit date: 2026-06-07. Scope: `desktop/` (Tauri shell + Svelte frontend, ~6.9k LOC frontend, 4 Rust files)._

## TL;DR

The app is a **fully-built UI skeleton over a 91%-mock backend**. The native shell
does exactly 3 real things (embedded kernel, file IO, daemon supervision). Everything
the user _experiences as a feature_ — chat, agent, tabs, settings, network, auth,
packages — is **theater**: the frontend calls a `commands` object whose 110 methods
all return hardcoded mock data.

**The keystone gap:** `src/lib/bindings.ts` declares **110 commands** (the contract every
feature depends on). The Rust backend implements **11**, and **none of them are the same
commands**. The 11 real ones are invoked directly via `invoke()`, bypassing `bindings.ts`.
The `tauri-specta` regeneration the whole frontend assumes (`bindings.ts:6-15`) is not even
a Cargo dependency yet. So the epic is fundamentally: **build the Rust backend that
`bindings.ts` already specifies the shape of.**

---

## The promise (from README + code)

Two tiers:
- **App (default, offline):** Tauri shell + embedded `oql.wasm` kernel + Svelte SPA.
  Open/edit/weave/validate/outline workbooks locally. Needs nothing else.
- **Runtime (optional):** Elixir BEAM in a container. Agents, multi-tenant, HTTP/WS,
  vectors, cloud sync. Connected only when wanted, via discovery file `{port, token}`.

User-facing promises implied by the UI surface: chat with an agent, voice/Gemini-Live
brainstorm, open tabs, command palette, terminal, file search, package/workbook browser,
bookmarks, themes, settings (agents/skills/plugins/MCP/integrations/keys/env), WorkOS
sign-in, network social feed, publish, auto-update.

---

## Verdict by bucket

### ✅ DELIVERED — real, works today (desktop build)

| Capability | Evidence |
|---|---|
| **Embedded OQL kernel** weave/tangle/validate/lint/outline, in-process via wasmtime | `kernel.rs` (oql.wasm 414KB compiled in, real component-model run); tests pass `kernel.rs:78-91` |
| **Live workbook editor** — weave+validate+outline as you type (250ms debounce) | `WorkbookView.svelte:68-89`, `kernel.ts:14-46` → real `invoke()` |
| **File open/save `.org`** — native dialog + Rust `std::fs` | `files.ts:12-33`, `lib.rs:78-84` |
| **Daemon supervision** — `work deploy local/status/down`, discovery file read | `daemon.rs`, `lib.rs:88-100` |
| **Runtime discovery + Bearer token** — reads `{port,token}`, attaches `Authorization` | `runtime.rs`→`runtime_url`, `runtime.ts:21-35` |
| **Sidecar health check** — real HTTP GET `/health` w/ token | `bindings.ts:525-533` (only command that actually calls `rt()`) |
| **Offline gate** — reachability guard + real engine restart | `router.ts:23-25`, `OfflineView.svelte:17-25` |
| **Auto-updater** — real Tauri plugin against GitHub Releases | `updater.ts:15-45`, endpoint in `tauri.conf.json` |
| **Window chrome** — frameless overlay titlebar, close→hide, tray menu | `lib.rs` tray + window events |
| **Tab/rail navigation UI + router** | `tabs.svelte.ts`, `router.ts`, `Titlebar.svelte` (store/event plumbing real; data mocked — see below) |
| **Theme apply** — tokens → `:root` CSS vars, active-id persists to localStorage | `theme.svelte.ts:75-137` |

### 🔌 WIRE-UP — UI + contract exist, backend command is a mock stub

These need a **Rust `#[tauri::command]` implementation** behind an already-defined
`bindings.ts` signature. Frontend code, types, and UI are done. Swap mock → `invoke()`.

| Capability | Mock location | What's missing |
|---|---|---|
| **Tabs (open/focus/close/list)** | `bindings.ts:549-561` | Rust tab manager + `tabs-state` event emit. Store/listener already wired `tabs.svelte.ts:29` |
| **Packages + workbook browser** | `bindings.ts:458-490` | Real package index / file walk; `packageWorkbooks` returns `[]` |
| **File search** | uses `packageWorkbooks` | Real corpus; UI + fuzzy filter done `SearchDrawer.svelte` |
| **Bookmarks (⌘1-9)** | `bindings.ts:340-351` | Persistence + list; UI done |
| **Agent settings** (default agent/model) | `bindings.ts:303-336` | Persist + serve catalog |
| **Skills / Plugins / MCP servers** | `bindings.ts:409-423,507-546` | Real list/install/toggle/persist; all return canned arrays |
| **Integrations / connections (OAuth + local CLI)** | `bindings.ts:354-371` | Real OAuth flow, CLI detection, keychain; all no-ops |
| **Keys / env vars** | `bindings.ts:379-404` | Real keychain-backed store |
| **Engine status** | `bindings.ts:374` | Real probe (returns canned `running/pid 4242`) |
| **Themes list/create/delete** | `bindings.ts:576-601` | Durable theme store (apply + active-id already real) |
| **Persistent store backend** | `store.svelte.ts:3-79` | Swap localStorage shim → `@tauri-apps/plugin-store` (TODO in-file) |
| **Settings/tabs cross-session persistence** | — | Falls out of the above; today only theme-id survives restart |

### 🏗️ BUILD — net-new feature, not just wiring

These have **UI placeholders but no backend contract and no real design** — the hard
part is the system behind them, not the IPC glue.

| Capability | State | Evidence |
|---|---|---|
| **Chat: send message to agent** | Composer submit only opens the drawer + clears text. No send. | `HomeView.svelte:52-67` (`TODO(chat): chatSession.send`) |
| **Chat: agent responds / thread** | No thread state, no stream, send button hardcoded `disabled`, no `agent-message` event type | `AgentPanel.svelte:47-56`, `ipc.ts:26-33` |
| **Voice / Gemini-Live brainstorm** | Mock transcript bubbles, `startVoice()` no-op | `HomeView.svelte:98-122` (`TODO(gemini-live)`) |
| **Command palette actions** | Only writes text back to composer; no action exec | `PaletteModal.svelte:45-51` |
| **Terminal drawer** | Static placeholder `<pre>`; no xterm.js, no pty, no session | `TerminalDrawer.svelte:5-7,53` |
| **WorkOS authentication** | `signIn()` returns `{bearer:"mock-bearer", email:"you@example.com"}` instantly. No browser, no PKCE, no loopback, no keychain, no persistent session | `auth.svelte.ts:116-129`, `bindings.ts:445-448` |
| **Network identity / DID** | `did:key:zMock` hardcoded; no keygen, no persist | `bindings.ts:426-442` |
| **Network social feed** | Hardcoded 2-post mock; no fetch despite real reachability gate | `NetworkView.svelte:10-16` |
| **Publish / fork workbook** | Returns `https://example.invalid/mock` | `bindings.ts:443-444` |

---

## The keystone: bindings.ts contract vs. real backend

```
bindings.ts commands declared:  110
Rust commands implemented:       11
Overlap:                          0   ← the 11 real ones bypass bindings.ts via direct invoke()
tauri-specta in Cargo.toml:      NO
```

`bindings.ts:6-15` states the intended mechanism: _"When the Rust backend + tauri-specta
land, this file is REGENERATED — the real version forwards each call through TAURI_INVOKE."_
That regeneration has never run; the dependency isn't present. **Every settings panel,
agent surface, tab, package, network, and auth feature is driven by `commands.*` → 100% mock.**

Real `invoke()` calls live only in `kernel.ts`, `files.ts`, `runtime.ts` (the 11 DELIVERED
commands) — they never go through `bindings.ts`.

---

## Validation path (how to prove the agent works in this environment)

The user's stated goal: validate that the agent works in the desktop app — chat in,
agent opens tabs, networking + auth real. Minimum chain, in dependency order:

1. **Backend scaffold:** add `tauri-specta` + `specta` to `src-tauri`; generate `bindings.ts`
   from real commands. Replaces the mock contract wholesale. _(unblocks everything below)_
2. **Auth real:** implement `network_workos_*` commands — system-browser + loopback +
   keychain. Without this, "networking + auth properly implemented" is unmet. `workos` skill applies.
3. **Runtime data path:** route `agentsList`/`entriesPage`/`network*` through `rt()` (the
   Bearer+fetch helper that already works) instead of mocks. Proves networking end-to-end.
4. **Chat backend:** define `chatSession.send` + an `agent-message` event; stream agent
   replies into `AgentPanel`. This is the core "interface in the chat" promise — net-new.
5. **Agent→tabs:** give the agent a command to open tabs (`tabOpen` real), so "have it open
   up tabs in the interface" is demonstrable. Requires #1 (real tab manager) + #4.
6. **GUI verification:** drive the running app via the `tauri-gui-testing` skill to confirm
   the full loop (type → agent → tab opens) end-to-end.

Net: **#1 + #2 + #3 + #4 + #5** is the spine of the epic. #1 is the unlock for the entire
WIRE-UP bucket as a side effect.

---

## Shippability blockers (separate from features)

- No Apple signing cert (codesign/notarize) — `README` "Not yet shippable".
- `work` bundling undecided (escript needs Erlang → Burrito-wrap ERTS, or reimplement deploy
  in Rust).
- Runtime image `ghcr.io/workbooks-sh/runtime` must be public for anonymous pull.

# Workbooks Desktop — Re-baseline Assessment

_Re-baseline date: 2026-06-09. Supersedes the 2026-06-07 audit (kept at
`ASSESSMENT.2026-06-07.md`), which described a pre-wire-up mock skeleton that no
longer exists._

## TL;DR — the board was stale, not the app

The 2026-06-07 audit called this a "91%-mock skeleton." A large wire-up landed
2026-06-08 and that verdict is obsolete. Code truth as of 2026-06-09:

- **Native Rust shell: done and thin.** 112 `#[tauri::command]`s, all registered;
  ~all are real OS glue (keychain, fs + watch, PTY terminal, krunvm/daemon
  supervision, window/tray) or the embedded `oql.wasm` kernel (weave/tangle/
  validate/lint/outline). Exactly **one** true stub (`plugins_install` writes
  metadata, doesn't fetch). This is the correct "thin hackable surface" — almost
  nothing business-logical lives in Rust.
- **Svelte frontend: ~95% wired**, not mocked. All 25 `src/lib/bridge/*` modules
  call real backends (Tauri `invoke` for OS/local state, HTTP/WS for runtime data).
- **WorkOS auth: code-complete** on both sides (loopback + PKCE + keychain, bridge,
  store). The `mock-bearer` the old audit cited is gone.

## The real problem: the desktop is wired to a DEAD runtime contract

**Canonical-source rule: the runtime (`runtime/host/`) is the source of truth.
The desktop app is the most out-of-date code in the repo.** Where they disagree,
the desktop is re-pointed onto the runtime — never the reverse.

The frontend was built against the **old monorepo's `oql-agent` Phoenix control
plane**, which is not in this repo. The new runtime (`runtime/host/web.ex`, a
Plug-style router — no Phoenix channels) exposes a different, smaller surface.
Net: the desktop's "95% wired" is 95% wired to endpoints that don't exist here.

### Contract mismatch (desktop calls → runtime serves)

| Desktop calls | Runtime actually serves | Verdict |
|---|---|---|
| `POST /api/agent/run` (`ws.svelte.ts:292`) | `POST /api/run` (`web.ex:154`) | RENAME / re-point |
| Phoenix `/socket` + 9 channels (`session:`, `runtime:telemetry`, `workspace:control`, `desktop:control`, `memory:control`, `workgate:control`, `engine:env_prompt`, `monorepo:watch`) | **no Phoenix at all**; telemetry is raw WS `GET /api/run/:id/stream` (`web.ex:169`) + poll `GET /api/run/:id` | REWRITE transport |
| `GET /api/agents/list`, `/api/agents/:slug/system_prompt` | — | MISSING |
| `GET /api/sessions` | — | MISSING |
| `GET /api/skills` | — | MISSING |
| `GET/POST/DELETE /api/memory/sources` | — | MISSING |
| `GET /api/wizards`, `POST /api/wizard/start`, `/api/wizard/:id/answer` | — | MISSING |
| `POST/PATCH/GET /api/oql/*` (board) | `POST /oql/parse` (`web.ex:57`) only | re-point / extend |
| `GET/POST /api/workspaces/sync` | — | MISSING |
| `POST /v1/network/shares` | — (network broker is external) | broker, see below |

For each MISSING row the decision is per-endpoint: either the desktop re-points to
an existing runtime verb, or the runtime is the right place to grow the endpoint
(canonical) and we add it there — but the desktop never gets a parallel
implementation in Rust.

## Two more real gaps (independent of the contract)

1. **Auth broker is down + drifted.** `auth.workbooks.sh` 404s on `/v1/auth/authorize`
   and `/v1/auth/exchange` (Cloudflare-fronted, not deployed; not in this repo). And
   the path drifts: desktop `network.rs` calls `/v1/auth/authorize`; the publish CLI
   (`toolkits/publish/bin/src/cmd/auth.rs`) calls `/v1/auth/start`. One contract must win.
   Until the broker is live, sign-in cannot complete regardless of app code.
2. **Network/social layer is demo-only.** `src/lib/network/client.ts:18` defaults to
   `"demo"` mode with no code path to `"live"`; `PreviewPane.svelte` hardcodes
   `workspace:"daily-driver"` and simulates upstream-pull with a `setTimeout`.

## Quality

`bun run check`: **6 errors, 39 warnings**. Known error: dead `"sidecar"` comparison
in `TerminalDrawer.svelte:340` (the union is `"daemon" | "shell"`). Clean-up is part
of the real remaining work, not optional polish.

## Delivered & correct (do not redo)

Embedded `oql.wasm` kernel; live weave/validate/outline editor; file open/save +
fs tree + watch; real PTY terminal; krunvm daemon supervise + discovery + Bearer
token + `/health`; offline gate; auto-updater; window/tray chrome; keychain-backed
keys/env/connections/identity; bookmarks/themes/MCP/workspaces/packages local stores;
WorkOS loopback+PKCE client (pending broker).

## The work, restated against the canonical runtime

1. **Re-point the transport.** Replace the Phoenix `Socket/Channel` bridge with the
   runtime's real shape: `POST /api/run` → `GET /api/run/:id/stream` (WS) → poll
   `GET /api/run/:id`. Drop the `phoenix` dep. This is the spine — chat + telemetry
   ride on it.
2. **Reconcile each HTTP bridge** (agents, skills, memory, wizard, oql/board,
   sessions, workspaces) to a real runtime endpoint; where the endpoint genuinely
   belongs in the runtime and is absent, add it **in `runtime/host`**, not the app.
3. **Stand up the auth broker** + resolve `/authorize` vs `/start` drift.
4. **Network demo → live** once auth + broker land.
5. **Green the type-check** (6 errors).
6. **Design open question (not code): workspaces vs packages vs apps-within-apps** —
   the desktop has both `workspaces.rs` and `packages.rs` stores; the new product
   framing ("apps within apps") needs an explicit model before these diverge further.

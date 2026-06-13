# Embedded MCP — Claude Code drives the browser (wb-aakl.11)

The workbooks browser exposes an **MCP server** so Claude Code (in
production, on the user's machine) can look at and drive it — replacing the
chrome-devtools MCP for our surface, and adding workbooks-native tools no
generic browser MCP can offer. This is the agent-facing seam: the browser
is an extensible desktop app an agent builds against.

This doc is the locked architecture. The Rust server + stdio relay land in
**wb-aakl.23**; the `wb desktop mcp` CLI entry point and this design ship
with wb-aakl.11.

## Decision: in-house thin server (not vendoring tauri-plugin-mcp)

Prior art — `P3GLEG/tauri-plugin-mcp` (UDS at `/tmp/<app>-mcp.sock`;
screenshot, DOM read, click/type/eval) and `hypothesi/mcp-server-tauri` —
proves the shape. We **build our own thin server** rather than vendor:

- We already have 112 `#[tauri::command]`s. The native tools are the
  differentiator and they map 1:1 onto those — vendoring buys us only the
  generic webview tools, which are a small slice of the surface.
- No new crates: a `std::os::unix::net::UnixListener` + a thread per
  connection + `serde_json` (already a dep) covers the transport. Keeps the
  bundle and the audit surface minimal.
- Full control over the curated toolset + the Waldo agent-to-agent tools.

## Transport

- **Socket:** `AF_UNIX` stream at `/tmp/workbooks-mcp.sock` (override
  `WB_MCP_SOCK`). Local-user only; created `0600`. Removed + recreated on
  app start. No TCP/network listener, ever.
- **Framing:** newline-delimited JSON-RPC 2.0 (one message per line).
- **Lifecycle:** the listener starts from the Tauri `setup()` hook, gated by
  `WB_MCP=1` (off by default so the plain app is unchanged; `wb desktop
  mcp` sets it). One accept-loop thread; one worker thread per connection,
  each holding a cloned `AppHandle`.

### Bridging to `claude mcp add`

Claude Code speaks MCP over **stdio**, not a UDS. `wb desktop mcp --stdio`
is a tiny relay: copy stdin → socket, socket → stdout. So:

```
claude mcp add workbooks -- wb desktop mcp --stdio
```

`wb desktop mcp` (no args) prints exactly this line plus the socket path and
whether the browser is running. The relay connects to the live browser's
socket; if the browser isn't running it exits with a clear message.

## MCP methods

- `initialize` → server info + capabilities (`tools`).
- `tools/list` → the manifest below.
- `tools/call` → dispatch by name; result is MCP `content` (text/JSON, or an
  image for screenshots).

## Toolset

### Workbooks-native (the differentiator — 1:1 to existing commands)

| MCP tool | Backed by | Notes |
|---|---|---|
| `tabs_list` | `tab_list` | open tabs + active |
| `tabs_open` | `tab_open` | open path/workbook as a tab |
| `tabs_focus` | `tab_focus` | focus by id |
| `tabs_close` | `tab_close` | close by id |
| `bookmarks_list` / `bookmark_add` / `bookmark_remove` | `bookmark_*` | |
| `workspace_tree` | `workspaces.*` + `packages.*` | the monorepo/workspace tree |
| `open_workbook` | `tab_open` + viewer | open a `.html`/`.org` by path |
| `weave` / `validate` / `outline` | `kernel::*` (oql.wasm) | weave/validate/outline a workbook |
| `viewer_state` | panes/tabs stores | what's open + focused |

These call the existing `pub fn` command bodies directly:
`app.state::<TabManager>()` etc. reconstructs the `State<_>` args, so the
MCP dispatch reuses the exact logic the UI invokes — no parallel impl.

### Generic webview (computer-use parity)

| MCP tool | Mechanism |
|---|---|
| `screenshot` | Tauri webview capture → PNG bytes → MCP image content |
| `dom_read` | inject JS, read `document.documentElement.outerHTML` via the bridge |
| `eval_js` | run JS in the focused webview, return its value via the bridge |
| `click` / `type` / `hover` | resolve a selector, dispatch synthetic events via the bridge |
| `list_windows` | `app.webview_windows()` |

**JS bridge:** Tauri's `webview.eval()` is fire-and-forget, so eval-with-
result and DOM tools need a round-trip: inject a helper that runs the JS and
posts the result back over a per-call channel (an `__WB_MCP__` callback +
a Tauri event the server awaits, keyed by call id). This is the most
involved piece and is the bulk of wb-aakl.23.

### Waldo (agent-to-agent, wb-aakl.21)

| MCP tool | Notes |
|---|---|
| `waldo_ask(question)` | ask the resident browser agent a question; returns its answer |
| `waldo_do(task)` | hand Waldo a task to perform in the browser |

These let Claude Code converse with Waldo directly — Claude Code asks,
Waldo answers or acts. Wired once Waldo lands (wb-aakl.21).

## Security

- UDS is local-user, `0600` — same trust domain as the user running the
  browser. No auth beyond filesystem permissions; no network surface.
- The MCP surface is exactly what the user can already do in the UI (it
  reuses the same commands), so it grants no new capability — it just lets
  the user's agent drive their own browser.
- Off by default (`WB_MCP=1` to enable); `wb desktop mcp` is the blessed
  on-ramp. A future setting can toggle it from the UI.

## Status

- ✅ `wb desktop mcp` CLI entry (prints config + `claude mcp add` line).
- ✅ Architecture + toolset locked (this doc).
- ⏳ Rust server + stdio relay + JS bridge → **wb-aakl.23** (needs the Tauri
  build-test loop + on-device MCP verification).

# Engine-targeted ops — `wb rt`, `wb ctk`, `wb dev`, `wb desktop`, `wb var`

Talking to a *running* runtime, configuring it, developing against it, and
installing the desktop client. For the full env contract see `../env.md`; for the
routes these commands hit see `../http.md`.

TOC: target resolution · wb rt · wb ctk · wb var · wb dev · wb desktop

## Target resolution (how a client finds the runtime)

`wb rt`, `wb ctk`, and `wb dev` resolve a target the same way (first wins):

1. **`WB_RUNTIME_URL`** (+ optional **`WB_TOKEN`**) — explicit; a remote/cloud
   runtime or CI.
2. **the local discovery file** `runtime.json` — written by a local daemon
   (`wb deploy local`, or a source runtime started with `WB_DESKTOP=1`). Yields
   `http://127.0.0.1:<port>` + a per-boot token.

No target → `no runtime: start one (wb deploy local) or set WB_RUNTIME_URL (+ WB_TOKEN)`.

## `wb rt` — drive a running runtime over HTTP (RCP client)

The CLI is just another client: resolve target + credential, speak the HTTP contract.

- **`wb rt status`** — fetches the public `/.well-known/workbooks-runtime`
  capabilities handshake + an authed `/health`. Prints the doc + the resolved target.
- **`wb rt get <path>`** — `GET <path>` (e.g. `/api/workbooks`, `/health`).
- **`wb rt post <path> [<json>]`** — `POST <path>` with an optional JSON body.
- **Output:** pretty JSON on success; the §4 error envelope + `(HTTP <code>)` on
  failure; `request failed: …` / `runtime unreachable at <url>` on transport error.

## `wb ctk await <run> [timeout_s]`

- **Need:** the agent (bash-only) opens a CTK review, then blocks until a human
  clicks Commit in the CTK shell.
- **Action:** polls `GET /api/ctk/review/<run>` (default 600s) until a review
  lands, then prints it. The human's Commit POSTs `/api/ctk/commit?run=<run>`.
- **Failure:** `timed out waiting for a CTK review on <run>`; `no such run: <run>`.

## `wb var` — the per-tenant variable store

- **Need:** keep config + secrets out of source; reference them in templates.
- **Action:** `wb var set <key> <value> [--secret]`, `wb var get <key>`,
  `wb var list`, `wb var ref <template>` (injects `{{var:KEY}}` / `{{secret:KEY}}`).
- **Secrets are ref-only:** `get` on a secret returns
  `<secret: N bytes — ref it with {{secret:KEY}}, cannot read>`; it can never be
  read back, only referenced. Default tenant for in-process calls is `dev`.
- There is no separate "memory" store by design — the org/code files ARE the
  context; recall is `wb search` (semantic) or `wb library query` (literal).

## `wb dev` — the local development service

Host-side. Works from a source checkout (boots a dev runtime via `mix`) or
against a deployed runtime (a client/harness over HTTP). Reuses `wb rt` target
resolution.

- **`wb dev info`** — the demo/dev environment at a glance: runtime URL + source
  + `[health: ok|unreachable|n/a]`, which model key is set, the toolkits root +
  count, and the CTK shell URL.
- **`wb dev up`** — how to start a dev runtime: source → `WB_WEB=1 iex -S mix`
  (control plane on :4000; add `WB_DESKTOP=1` to also write the discovery file);
  prod-parity → `wb deploy local`.
- **`wb dev test [args]`** — run the runtime test suite (`mix test`) from a source
  checkout. No `mix.exs` found → instructs you to use `wb rt` against a deployed runtime.
- **`wb dev eval [id]`** — list toolkit eval suites (`<root>/*/evals/*.org`), or
  run one server-side (= `wb toolkit eval`, sandboxed; set `WB_TOOLKIT_EXEC=1`).
- **`wb dev ctk`** — the CTK review-shell URL served by the connected runtime, and
  the `?connect=` form that wires a review to a run.

Model keys `wb dev info` looks for: `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY` (any one suffices for agent runs).

## `wb desktop` — install + launch the GUI app

Host-side; shells out. The desktop app is the GUI shell whose first-run wizard
connects an engine (it runs offline without one).

- **`wb desktop install [--version=X]`** — pipes the canonical `install.sh`
  (`https://workbooks.sh/install.sh`, override with `WB_INSTALL_URL`) through
  `sh`. `--version=X` pins release tag `desktop-vX` (via the `WB_VERSION` env the
  script reads).
- **`wb desktop open`** — launch the installed app (`open -a Workbooks` on macOS;
  the `workbooks` binary on Linux).
- **Failure:** `could not launch … — install it first with wb desktop install`.

## `wb version`

Prints `wb <version>`.

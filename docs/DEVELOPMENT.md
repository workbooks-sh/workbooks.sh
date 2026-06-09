# Local development & verification

> **Principle:** never wait for a CI → production build to find out if a change
> works. Verify at the *tightest tier* that proves it, locally. This is a shipped
> capability — `wb dev` — so anyone running a Workbooks runtime (us, or a
> DeployKit user extending theirs) has the same clean path.

## Entry point: `wb dev`

```
wb dev info          # the demo/dev environment at a glance
wb dev up            # how to start a dev runtime (source mix / prod-parity krunvm)
wb dev test [args]   # run the runtime test suite (mix test) — source checkout
wb dev help
# planned: wb dev eval (agent eval suite) · wb dev ctk <toolkit> (serve a render toolkit)
```

Two modes, auto-resolved: a **source checkout** boots the dev runtime from `mix`
(the escript can't host the OQL/wasmex NIF); a **deployed runtime** is driven as
a client over HTTP (the `wb rt` target: `WB_RUNTIME_URL`/`WB_TOKEN` or the local
discovery file).

## The three tiers

### 1. Per-surface inner loop (seconds)
- **Runtime** — `WB_WEB=1 iex -S mix` (control plane on `:4000`; add `WB_DESKTOP=1`
  to also write the desktop discovery file). Unit/contract suite: `wb dev test`
  (= `mix test`, ~58 files). `mix compile` is the first gate for any runtime edit.
- **Desktop frontend** — `cd desktop && bun run dev` → `:5178`. Runs the *real*
  44k-LOC frontend with `$lib/platform/webHost` mocking the providers (no runtime
  needed). A Vite plugin forces a full reload on every `src/` edit, so changes
  always propagate (no HMR-wedge).
- **Toolkits / CTK** — `cd toolkits/ctk && python3 -m http.server 5180` →
  `http://localhost:5180/ctk.html`. Toolkit discovery/skills: `wb toolkit list |
  show <id> | verify <id>`.

### 2. Integration loop (minutes, no container)
Boot the runtime from source (`WB_WEB=1 iex -S mix`), then point a client at it:
`wb rt status` / `wb rt get <path>`, and `wb dev info` for the env summary. The
CTK human-in-the-loop round-trip lives here (a real `/api/run` + `wb ctk await`).
> Gap: pointing the *browser* desktop preview at a live local runtime (instead of
> the webHost mock) is not wired yet — that's the WebHost "live providers" mode
> (epic `wb-lk6`). Today the browser preview is mock-only; the Tauri app is the
> live-runtime path.

### 3. Production-parity loop (slower, exact)
`wb deploy local` — the **same OCI image as production** in a krunvm container
(krunvm/docker present locally). Use this to replicate production without a
CI/CD → cloud build.

## Evals ("workbench")
The agent eval / trajectory suite is the runtime's behavioral test (distinct from
the CTK *component* bench). `wb dev eval` will front it; today brandnana evals
live at `projects/brandnana/evals`. Default eval model: `xiaomi/mimo-v2.5`.

## What you need
- **Elixir/OTP** (compile + run the runtime), **bun** (desktop), **python3**
  (serve a render toolkit), **krunvm or docker** (prod-parity).
- An **LLM key** for agent runs (`OPENROUTER_API_KEY` etc.) — `wb dev info`
  reports which are set.

See also: `desktop/docs/platform-model.md` (one Host, many targets),
`runtime/docs/TOOLKITS-V3.org` (toolkit EXEC modes), `toolkits/ctk/` (the CTK loop).

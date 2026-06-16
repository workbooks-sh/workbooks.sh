# Agent Instructions

The single, tool-agnostic instruction file for any AI coding agent on this project.

## Four Golden Rules of Development

Consider these at **every turn**, before writing or accepting any code:

1. **DRY** — Is this code DRY enough? No copy-paste of logic that should have one home.
2. **Least code** — Is this written in the fewest lines of code possible? Prefer deleting and leaning on deps over adding.
3. **Componentize** — Can this be shared across multiple consumers instead of rewritten? Reduce duplication by increasing the dependency on one well-factored component, not by re-implementing.
4. **Drift** — Do we have drift, and is that drift causing the issue right now? Fix it by aligning around the right idea, not by patching around the wrong one.

## Issue Tracking (bd / beads)

This project uses **bd** (beads) for task tracking — not TodoWrite, markdown TODO lists, or `MEMORY.md`. The `.beads/` data is **local-only and git-ignored — never commit or push it to git** (it's a public-repo liability). bd's git auto-backup is intentionally disabled (`backup.enabled` + `backup.git-push: false` in `.beads/config.yaml`); **do not re-enable it**. bd works entirely off its local Dolt db — no git sync of any kind (history was scrubbed of `.beads` + force-pushed 2026-06-09).

```bash
bd ready                 # find available work
bd show <id>             # view an issue
bd update <id> --claim   # claim work
bd close <id>            # complete work
bd prime                 # full workflow context + session-close protocol
```

## Non-Interactive Shell

Always pass non-interactive flags — `cp`/`mv`/`rm` may be aliased to `-i` and hang waiting on a y/n prompt.

```bash
cp -f source dest        # mv -f, rm -f, rm -rf, cp -rf
ssh/scp -o BatchMode=yes
apt-get -y               # brew: HOMEBREW_NO_AUTO_UPDATE=1
```

## Session Completion

Work is **not** complete until `git push` succeeds. Before ending a session:

1. File issues for any follow-up work.
2. Run quality gates if code changed (tests, linters, build).
3. Update issue status — close finished, update in-progress.
4. Push: `git pull --rebase && git push` — `git status` must show up-to-date with origin.
5. Hand off — leave context for the next session.

Never stop before pushing; never say "ready to push when you are" — you push.

## Architecture canon — desktop / web / mobile

One frontend, many targets. The UI talks to a **single Host capability surface**
(the `invoke` seam, generalized — the Dock membrane). Behind it a router
fulfills each capability from a **provider**: `local` (OS via Tauri, or
browser-native) or `runtime` (a shared server over RCP / HTTP+WS). A *target*
(desktop/web/mobile) is just a **routing config** + runtime endpoint — not a
code fork. Do NOT reintroduce a second "runtime contract" the UI manages, and do
NOT try to compile the Tauri/OS layer to WASM; swap providers behind the one
Host instead.

A **workbook is an HTML file** built from the `work-*` Lit web-component library
(`workponents/`); the browser renders it. There is no org-mode, no OQL kernel,
and no bespoke format — where the backend must read a workbook's structure (the
compiler finding `<work-component>` source; validation; an outline) it parses
the HTML with a standard parser (`Workbooks.Workbook` over Floki). Authoring is
HTML-only; internal tooling JSON is fine.

- **Canon doc:** `desktop/docs/platform-model.md` · **epic:** `wb-lk6` · **runtime connect:** RCP `wb-uxn`.
- **Desktop state of truth:** `desktop/ASSESSMENT.md` (the runtime is canonical; the desktop frontend is the most out-of-date code — re-point it onto `runtime/host`, never the reverse).
- Browser preview: `cd desktop && bun run dev` (port 5178) — runs the real frontend with `$lib/platform/webHost` mocking the providers; no runtime needed.

## Local development & verification — `wb dev`

Never await a CI → production build to verify a change; run it locally at the
tightest tier that proves it. The methodology is a shipped CLI surface so
DeployKit users get the same path. **Canon doc:** `docs/DEVELOPMENT.md`.

- **`wb dev info`** — demo-env dashboard (runtime target + `/health`, model key,
  toolkits root, CTK URL). `wb dev up` / `wb dev test` (= `mix test`).
- **Runtime:** `WB_WEB=1 iex -S mix` (control plane `:4000`); `mix compile` is the
  first gate for any runtime edit; `mix test` (~58 files) the suite.
- **Desktop:** `cd desktop && bun run dev` (`:5178`, real frontend + webHost mock
  providers, full-reload on every edit).
- **Toolkits/CTK:** `cd toolkits/ctk && python3 -m http.server 5180`; `wb toolkit verify <id>`.
- **Prod-parity:** `wb deploy local` (same OCI image, krunvm container).

## Release / publishing — THREE separate layers. DO NOT CONFLATE THEM.

This tripped up a session badly once. Keep these distinct:

### 1. Compilers package — `ghcr.io/workbooks-sh/compilers:{latest,<sha>}`
- **What:** the in-sandbox wasm compiler toolchain (clang / mrustc+libstd / zig / go-yaegi / quickjs-ng) **plus the JS npm lane** (`compilers/js/bundle/bundlejob.js`, `compilers/js/shims/*`, `compilers/js/harness.o`, `compilers/js/harness_dock.o`). Its **own ghcr package**.
- **Why manual:** gitignored artifacts from an hours-long provision chain. **CI cannot build it.**
- **How to publish:** from a **provisioned machine**, occasionally — only when the compilers actually change. A bare maintainer function, **not a CLI command**:
  ```
  cd runtime && mix run --no-start -e "IO.inspect(Workbooks.Deploy.Image.publish_compilers())"
  ```
  Needs `docker login ghcr.io` + the `wb-multi` buildx builder (multi-arch amd64+arm64).
- **Staging allowlist:** `runtime/scripts/stage-tools.sh` decides what goes in the layer (explicit `take` lines → `compilers-dist/`). **Add a `take` for any new compiler asset** or it silently won't ship (this is exactly how the whole npm lane went missing once).
- This is **NOT** `wb deploy`.

### 2. Runtime image — `ghcr.io/workbooks-sh/runtime:{latest,<sha>}`
- **What:** the BEAM runtime + wasmtime + litestream + the release. Contains `runtime/host/**` (the engine code).
- **How:** built by **CI/CD** — `.github/workflows/runtime-image.yml` on push to main. It `COPY --from`s the **compilers package (layer 1)**.
- **So:** runtime code change → push to main, CI builds it (nothing manual). Compilers change → publish **layer 1 first** (manual, above), THEN CI rebuilds the runtime image on top.

### 3. `wb deploy` (Deploy Kit) — USERS ONLY
- **What:** the tool for **consumers with our CLI** to deploy the runtime image for **their own use** — locally (krunvm) or cloud (Fly), to **their** registry via `WB_IMAGE`. Verbs: `init / validate / apply / update / verify / status / logs / down` (+ internal `build`/`publish` pushing to a registry the user controls).
- **NOT** how *we* publish the compilers package or platform runtime image. **Never wire platform-release ops into `wb deploy`.**

**Rule of thumb:** *compilers* ship as their own ghcr package, published **manually**. The *runtime* ships via **CI**. **`wb deploy` is the user's tool to run the runtime** — not a platform-release mechanism.

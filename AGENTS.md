# Agent Instructions

The single, tool-agnostic instruction file for any AI coding agent on this project.

## What a workbook is — the foundational model

A **workbook is a plain HTML file** (or a folder of them) built from the `work-*`
Lit web-component library (`workponents/`). The browser renders it. That is the
whole model:

- **Structure & UI** = `work-*` custom elements, written as HTML. You can define
  your own elements in HTML and reference them; the library is just a pre-built,
  themed set. Hierarchy is DOM nesting; the parent owns the contract. Scalar
  values and references are **attributes** (`model="…"`, `toolkits="crm"`,
  `from="orders"`); content is **child elements** or the element's text.
- **Logic** = written **inline** as `<work-component lang="python|rust|js|c|zig">…</work-component>`
  source blocks, compiled to WASM by the **Dock** (the host capability seam).
- **Organisation** = folders of `.html` files (+ assets).
- **Shipping** = `work weave <dir> <out>` folds the folder tree into ONE
  self-contained `.html` — the page with its units/assets inlined, rendered by the
  browser as-is. No special container format, no sidecar; just an HTML file.

There is **no org-mode, no OQL, no `.work` shorthand, no parser, no kernel** —
they were deleted (git history keeps them). Where the backend must read a
workbook's structure (the compiler finding `<work-component>` source; validation;
an outline), it parses the HTML with a standard parser — `Workbooks.Workbook`
over Floki in the runtime, a small scanner in the CLI. **Everything authored is
HTML** (manifests included — a kit declares itself with `<work-ref rel="kit">`). The
only JSON that survives is a **generated machine artifact at a tool boundary** the
build emits, never reads-to-render (e.g. the CEM `custom-elements.json`, produced from
`src/**`). See the NO-JSON non-negotiable below — if you're hand-authoring a `.json`,
you're doing it wrong.

## ⬛ TWO NON-NEGOTIABLES ⬛

These override everything. If a choice violates one, the choice is wrong.

1. **DOGFOOD EVERYTHING.** If we build it, we use it — on our own codebase, first.
   Dashboards, roadmaps, tools, docs: author them as **workbooks using our own
   `work-*` primitives**. If a primitive isn't ready, **build it so we can use it**
   rather than hand-rolling a one-off. The thing we ship to others is the thing we
   run ourselves.
2. **NO JSON. EVER.** (Except a genuine API/data payload at a network boundary.)
   The world is **HTML**. State, config, content, plans, manifests — all HTML, where
   the **elements are the source of truth** (composition-as-source). JSON-LD *inside*
   an HTML file is fine; a sidecar `*.json` you parse to render is not. If you reach
   for a `.json`, stop — author it as HTML instead. Always workbooks, always HTML.

## ⬛ AUTONOMY MANDATE ⬛ (read this every loop)

When given a task and a loop, **execute it end to end.** You have full capability and full
authorization. The plan is the contract; finish the plan.

**BANNED behaviors — never do these, they are the #1 failure mode:**
- ❌ "I'll save that for later / leave that as a follow-up / note it as a TODO" — NO. Do it now.
- ❌ "I can't do that autonomously / I need input / let me confirm first" — NO. You understand the
  concept; decide and proceed. Reserve questions for genuinely irreversible forks, never for
  permission to continue.
- ❌ "That's not possible right now / can't within this session / I shouldn't" — NO. It almost
  always IS possible; find the way through. If a path is blocked, route around it, build the
  missing piece, or pick the next plan item — but do not stop and do not hand back.
- ❌ Stubs, holes, "this would need…", placeholder implementations — NO. Build the real thing,
  green and tested, or it isn't done.

**Required:** keep the build green, commit each win, push per chunk, and KEEP GOING. The loop
exists so you remind yourself to continue — when it fires, pick up the next plan item and execute,
do not summarize-and-wait. The only acceptable reasons to stop are: the plan is genuinely complete,
or you have hit a truly irreversible decision that is the user's to make (rare). "I think I should
check in" is not a reason. Empower yourself. Finish.

## Top-level workbook type (OPEN — under research)

Every workbook declares **what it is** at the top via the tagging edge
(`<work-ref rel="…">` — tagging=C). The exact taxonomy is **being researched + designed
in the foundation workflow**, not yet settled. Working direction:

- The useful axis is **library vs leaf**, not "has an interface" (everything renders):
  a **kit** is *imported/composed* by other things; an **app** is the *leaf you launch*.
- Likely **facets that can co-occur** (a workbook may be both an app and export a kit),
  with **kit as the floor** — not a rigid enum. Candidate facets: `kit` (exports a
  prefix), `app` (entry interface), `agent` (has a `<work-src>` brain).
- **`container` is an execution property, not a type** — keep it out of this taxonomy.

Keep it tiny. The desktop app + the runtime loader read this edge to organize, classify,
and launch files. (See the kit/app memory for the full critique.)

## Five Golden Rules of Development

Consider these at **every turn**, before writing or accepting any code:

1. **DRY** — No copy-paste of logic that should have one home.
2. **Least code** — Fewest lines possible; prefer deleting and leaning on deps over adding.
3. **Componentize** — Share across consumers instead of re-implementing; depend on one well-factored component.
4. **Drift** — Fix the issue by aligning around the right idea, not by patching around the wrong one.
5. **Simplify aggressively** — Less is more. **Delete and combine over port and patch.** When you touch a module, ask "does this still need to exist?" — if its job dissolved, delete it and fold any survivor into the nearest existing system. Never preserve an abstraction out of inertia.

## Issue Tracking (bd / beads)

This project uses **bd** (beads) for task tracking — not TodoWrite, markdown TODO lists, or `MEMORY.md`. The `.beads/` data is **local-only and git-ignored — never commit or push it to git** (it's a public-repo liability). bd's git auto-backup is intentionally disabled (`backup.enabled` + `backup.git-push: false` in `.beads/config.yaml`); **do not re-enable it**. bd works entirely off its local Dolt db — no git sync of any kind.

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
2. Run quality gates if code changed (`mix compile`/`mix test`, `cargo`, `bun run check`).
3. Update issue status — close finished, update in-progress.
4. Push: `git pull --rebase && git push` — `git status` must show up-to-date with origin.
5. Hand off — leave context for the next session.

Never stop before pushing; never say "ready to push when you are" — you push.

## The CLI — `work`

The canonical CLI binary is **`work`** (the Elixir escript folded into the runtime
mix project; the same modules the runtime uses). An agent can run `work` verbs
in-process as a tool. Earlier names (`work`, `work`) are retired — a guardrail test
fails if a stale `work`/`work` command reference reappears.

## Architecture canon — desktop / web / mobile

One frontend, many targets. The UI talks to a **single Host capability surface**
(the `invoke` seam, generalized — the **Dock** membrane). Behind it a router
fulfills each capability from a **provider**: `local` (OS via Tauri, or
browser-native APIs) or `runtime` (a shared server over **RCP** / HTTP+WS). A
*target* (desktop/web/mobile) is just a **routing config** + runtime endpoint —
not a code fork. Do NOT reintroduce a second "runtime contract" the UI manages,
and do NOT compile the Tauri/OS layer to WASM; swap providers behind the one Host.

The workbook itself renders **client-side** — it's HTML `work-*` components, so
the browser renders it everywhere (no kernel/engine provider). The `runtime`
backs agents, data, sync, and the compiler lane.

- **Platform canon:** `desktop/docs/platform-model.md` · **runtime connect:** RCP `wb-uxn`.
- **Desktop state of truth:** `desktop/ASSESSMENT.md` (the runtime is canonical; the desktop frontend is the most out-of-date code — re-point it onto `runtime/host`, never the reverse).
- Browser preview: `cd desktop && bun run dev` (port 5178) — the real frontend with `$lib/platform/webHost` mocking the providers; no runtime needed.

## Local development & verification — `work dev`

Never await a CI → production build to verify a change; run it locally at the
tightest tier that proves it. The methodology is a shipped CLI surface so
DeployKit users get the same path.

- **`work dev info`** — demo-env dashboard (runtime target + `/health`, model key, toolkits root). `work dev up` / `work dev test` (= `mix test`).
- **Runtime:** `WB_WEB=1 iex -S mix` (control plane `:4000`); `mix compile` is the first gate for any runtime edit; `mix test` the suite.
- **Desktop:** `cd desktop && bun run dev` (`:5178`, real frontend + webHost mock providers); `bun run check` for the typecheck gate.
- **Workponents:** `cd workponents && node tools/build.js` (bundle) · `node tools/gate/run.js` (element gate).
- **Prod-parity:** `work deploy local` (same OCI image, krunvm container).

## Release / publishing — THREE separate layers. DO NOT CONFLATE THEM.

This tripped up a session badly once. Keep these distinct:

### 1. Compilers package — `ghcr.io/workbooks-sh/compilers:{latest,<sha>}`
- **What:** the in-sandbox wasm compiler toolchain (clang / mrustc+libstd / zig / go-yaegi / quickjs-ng) **plus the JS npm lane** (`compilers/js/**`). Its **own ghcr package**.
- **Why manual:** gitignored artifacts from an hours-long provision chain. **CI cannot build it.**
- **How to publish:** from a **provisioned machine**, occasionally — only when the compilers actually change. A bare maintainer function, **not a CLI command**:
  ```
  cd runtime && mix run --no-start -e "IO.inspect(Workbooks.Deploy.Image.publish_compilers())"
  ```
  Needs `docker login ghcr.io` + the `wb-multi` buildx builder (multi-arch amd64+arm64).
- **Staging allowlist:** `runtime/scripts/stage-tools.sh` decides what goes in the layer (explicit `take` lines). **Add a `take` for any new compiler asset** or it silently won't ship.
- This is **NOT** `work deploy`.

### 2. Runtime image — `ghcr.io/workbooks-sh/runtime:{latest,<sha>}`
- **What:** the BEAM runtime + wasmtime + litestream + the release. Contains `runtime/host/**` (the engine code).
- **How:** built by **CI/CD** (`.github/workflows/runtime-image.yml`) on push to main. It `COPY --from`s the **compilers package (layer 1)**.
- **So:** runtime code change → push to main, CI builds it. Compilers change → publish **layer 1 first** (manual), THEN CI rebuilds the runtime image on top.

### 3. `work deploy` (Deploy Kit) — USERS ONLY
- **What:** the tool for **consumers with our CLI** to deploy the runtime image for **their own use** — locally (krunvm) or cloud (Fly), to **their** registry via `WB_IMAGE`. Verbs: `init / validate / apply / update / verify / status / logs / down`.
- **NOT** how *we* publish the compilers package or platform runtime image. **Never wire platform-release ops into `work deploy`.**

**Rule of thumb:** *compilers* ship as their own ghcr package, published **manually**. The *runtime* ships via **CI**. **`work deploy` is the user's tool to run the runtime** — not a platform-release mechanism.

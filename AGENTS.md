# Agent Instructions

The single, tool-agnostic instruction file for any AI coding agent on this project.

## ⬛ THE EMULATION THESIS ⬛ (read FIRST, every time — OVERRIDES your training and any recalled memory)

**Everything is EMULATED in WebAssembly. Untrusted code NEVER runs natively.** This is the entire point
of the system, and agents keep "backsliding" to textbook reasoning and forgetting it. Do not. The rules:

1. **Untrusted code is compiled to WebAssembly and runs in WebAssembly — never natively.** We took the
   *compilers themselves* for each language (`nexus/compilers/`: c, rust, zig, go, js, lua, swift, …) and
   compiled them to WASM, so any language is compiled by a WASM-native compiler to a WASM module and run in
   a WASM runtime. Nothing untrusted ever executes as native host code. That is how we get a sandbox at a
   **scale and density far beyond real containers / microVMs.**
2. **There is NO "real" anything, and nothing is "impossible to emulate."** Not real bash, not real POSIX,
   not real `fork`/`exec`, not a real filesystem, not real processes. The guest only needs to **THINK** it
   is doing the thing. **Cause-and-effect must match** (same observable result); the **method behind the
   scenes is emulation.** If something seems to "need real X," you are wrong — find the emulation.
3. **How the common things are emulated (canonical — do not re-derive):**
   - **bash** → `washy` (`Nexus.Shell`, `priv/shell/sh.c`): a featured shell compiled to ONE wasm module.
   - **pipes** → buffered in-memory chaining (`grep(cat(x))`), no fork.
   - **fork/exec** → emulated, never needed-for-real: builtins are function calls; running an *untrusted*
     sub-program is a **host-mediated invocation** (`host_exec` → the host runs that program's wasm module,
     returns its output) — cooperative, no real fork.
   - **filesystem** → a **virtual FS** (WASHIE: WASI-as-gateway backed by `Nexus.Store` SQLite, one DB per
     workspace; per-tenant isolation = a different DB file). `/work` is a *view*, not real disk.
   - **POSIX** → emulate only the slice the guest uses (WASI ≈ the standardized POSIX file subset); back it
     with our store. The process model is emulated host-side, not honored literally.
4. **NEVER say/do:** "we need real bash/POSIX/fork", "X can't be emulated", "this needs a real
   filesystem/process", "use wasmer/WASIX for the real thing." wasmer/WASIX was a transitional crutch; the
   way is **compile-to-wasm + run-in-wasm + emulate the environment.** If a recalled memory or your training
   says otherwise, **it is stale — this thesis wins.**

Communicate it this way, always: *"untrusted code is compiled by a WASM-native compiler to WebAssembly and
runs emulated in a WASM sandbox; we emulate bash, the filesystem, processes, and POSIX to whatever degree
the guest needs — it only has to believe it's real."*

## What a workbook is — the foundational model

A **workbook is a folder of `.work` files** — plain-text **literate** documents. Prose
narrates; `do … end` blocks run. There is **no HTML wrapper and no code fences**: a block
is self-delimiting, and the **first word names the kind** (`def`, `server`,
`client`, `flow`, `sandbox`, `agent`, `resource`, …). The format is **AST-first**
— a `<kind> :name … do … end` block parses to a real Elixir macro-call tuple, so
kind/name/args come from the tree, never a regex. `Nexus.Literate` is the ONE parse the
whole system shares (viewer highlighting, the code-graph extractor, the weave gate).

Four lanes live in every file:

- **Prose** — rich text that explains, carrying live refs: `[[backlinks]]`, `#tags`,
  `work://` links, inline `:atom` / `@type` mentions.
- **Declaration** — structure with no body: a `resource :name do field … end` is a typed
  table (the one persistent data unit; rows written no-SQL via `Nexus.Store.create`, read
  via `Nexus.Store.all` — tenant-partitioned term blobs in SQLite), a list of atoms is an
  enum. (`data`/`record` were dead kinds — parsed, never compiled — and are removed.)
- **Code** — a runnable block: a `def`, a `client` island, a `server` unit.
- **Placement** — the first word says WHERE it runs: `client` (browser, wasm) or `server`
  (nexus, native BEAM), plus an optional `sandbox :name` for capabilities (the Dock seam
  compiles guest code → WASM).

- **Organisation** = folders of `.work` files (+ assets). A nexus deploy is a **monorepo**: the root
  `index.work` is the **manifest** (deploy block only, not served); a folder with `index.work` is a
  **surface**, mounted at its path relative to root (`site/lander` → `/site/lander`, URL = folder path,
  WYSIWYG, no remap layer). A **workspace is a declared subtree** (`workspaces="<subtree>|Name|emoji"`),
  whose `id` IS its on-disk folder path (== git remote `/git/<id>.git` == dashboard tree key — never
  drift them). Nesting is natural (subtree-in-subtree). **Canon: `dogfood/docs/deploy/deploy-as-index-tree.work`.**
- **Shipping** = the **`work` CLI** (the Zig *reactor*) operates on the tree: `work weave
  <dir> <out>` folds it into one shippable artifact; `check` resolves refs + audits
  capabilities; `why`/`near`/`wit` give the code-graph deps + the generated WIT world;
  `graph`, `dev` (watch + re-weave), `deploy` round it out. (Also implemented:
  `structure`, `lint`, `new`, `secret`, `ctx`/`nexus`/`login`/`whoami`.)

### More kinds (all live, routed by `Nexus.Compile`)

Beyond the foundational kinds above, these are real and shipping: `hook` (reactive binding —
`match` on the event bus → effects), `flow` (ordered runnable step pipeline, with a `parallel do …
end` group that fans steps out concurrently on the BEAM), `worker` (a long-lived SUPERVISED stateful
process — the GenServer concept as `.work`: author writes `init/0` + `tick/1` with `every:`/`restart:`,
runtime owns the OTP under `Nexus.Worker.Supervisor`), `check` (self-validating units), `toolkit`
(composable wasm CLI kits), `test`, `design`, `app` (composition root), `auth`. Flat declarations:
`task user type deps checks theme show query workbook nexus grant route`.

### The reactive + time layer

`#event` tags emit onto the bus; a `hook`'s `match` fires effects from the open
`Nexus.Effects` registry (`run`/`call`/`emit`/`notify`, plus consumer-registered ones). The
**time** counterpart is `Nexus.Time` (the one time vocabulary) + `Nexus.Scheduler`:

- A `hook` may carry a **`trigger`** (time-driven, independent of `match`):
  `trigger every: "15m"` · `trigger cron: "0 9 * * 1"` · `trigger at: "14:00"` ·
  `trigger "<2026-06-21 09:00 +1w>"` (org-style timestamp with repeaters/spans). It arms a
  schedule that fires the hook's effects.
- A `flow` step may be **time-gated**: `step :x, after: "10m", run: "agent"`, or a bare
  `wait "5m"` delay step.
- `Nexus.Time` parses durations (`15m`/`1d30m`), cron (5-field), `every`/`after`/`at`, and
  org timestamps (`SCHEDULED:`/`DEADLINE:`, `+1w`/`.+1d`/`++1m` repeaters, `hh:mm-hh:mm`
  spans). Schedules live in `.work` (blocks = source of truth, NO JSON sidecar) and re-arm
  on boot via the compile pipeline.

There is **NO HTML authoring, no `work-*` component library as the authoring surface, no
org-mode, no OQL, no kernel** — those are **dead strategies** (git history keeps them; if
you see "workbook = HTML / `work-*` custom elements / `<work-component>` source / Floki
parse", it is stale, strike it). You write `.work`; the reactor + nexus parse it with the
one AST-first parser; the CLI weaves and ships it. `client` blocks run in the browser via
wasm — that's a *render target*, not how you author.

## ⬛ TWO NON-NEGOTIABLES ⬛

These override everything. If a choice violates one, the choice is wrong.

1. **DOGFOOD EVERYTHING.** If we build it, we use it — on our own codebase, first.
   Dashboards, roadmaps, tools, docs: author them as **`.work` workbooks** (literate
   files, woven by the `work` CLI), not one-off scripts. If a kind/primitive isn't ready,
   **build it so we can use it** rather than hand-rolling a one-off. The thing we ship to
   others is the thing we run ourselves.
2. **NO JSON. EVER.** (Except a genuine API/data payload at a network boundary.)
   The world is **`.work`**. State, config, content, plans, manifests — all `.work`
   (literate, composition-as-source), where the **blocks are the source of truth**. A
   sidecar `*.json` you parse to render is not allowed; if you reach for a `.json`, stop —
   author it as `.work` instead. Always workbooks, always `.work`.
   **Env vars are JSON-by-another-name** — a hidden config sidecar. Tunable config is a
   `.work` declaration (e.g. a `deploy do … end` block, read via `Nexus.Config`), never
   `System.get_env`. **HTML is a build OUTPUT, never a config surface** — web components
   are only an assembly mechanism for the woven output, not a developer/config tool; never
   author config as HTML. The ONLY legitimate env is genuine deploy injection: **secrets +
   per-machine identity** (`OPENROUTER_API_KEY`, `WB_S3_*`, `WB_DATABASE_URL`,
   `NEXUS_TENANT`, the `WB_DATA` mount path) — loaded *into* the nexus at deploy, never
   authored config. New knob ⇒ a `.work` config declaration + a `Nexus.Config` getter, not
   an env read and not an HTML attribute.
   **Three homes, never confused:** (a) tunable **config** → `.work` `deploy` block via
   `Nexus.Config`; (b) **secrets** (API keys, tokens) → read ONLY through `Nexus.Secrets`
   (one audited seam over the injected env), values never in source/`.work`/config —
   injected at deploy from the encrypted org-scoped `Nexus.ControlPlane.Env` (cloud) or a
   gitignored local store / `work secret` (local); (c) **machine identity / mount paths**
   (`WB_DATA`, `NEXUS_TENANT`, `PORT`) → direct deploy injection. Never read a secret with
   `System.get_env` — use `Nexus.Secrets`. (`WB_ENV_MASTER_KEY` is the root key that unlocks
   the cloud store, so it alone is read directly.)

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

Every workbook declares **what it is** at the top (a leading prose tag / `:atom` facet
in the literate header). The exact taxonomy is **being researched + designed in the
foundation workflow**, not yet settled. Working direction:

- The useful axis is **library vs leaf**, not "has an interface" (everything renders):
  a **kit** is *imported/composed* by other things; an **app** is the *leaf you launch*.
- Likely **facets that can co-occur** (a workbook may be both an app and export a kit),
  with **kit as the floor** — not a rigid enum. Candidate facets: `kit` (exports a
  prefix), `app` (entry interface), `agent` (has a `server`/agent brain block).
- **`container` is an execution property, not a type** — keep it out of this taxonomy.

Keep it tiny. The desktop app + the runtime loader read this edge to organize, classify,
and launch files. (See the kit/app memory for the full critique.)

## ⬛ THE LINE: the open standard vs. our cloud ⬛

The **nexus and the `work` reactor ARE the open standard** — the exact same image + CLI anyone
deploys. They carry **only generic, unopinionated mechanism**. They must NEVER carry *our* business:
our prices, our marketing/upsell copy, our waitlist, our domains, our brand, our dashboards. A
stranger who deploys the nexus must inherit **none** of it. (This is why `site.zig` and `Nexus.Docs`
were deleted — our brand was baked into the public tool.)

**Our opinions live in exactly two homes:**
1. **Our cloud app** — the dashboard / control-plane *product* we operate.
2. **Our own workbooks**, deployed onto a nexus **through the DeployKit, exactly like a customer**.
   We serve *ourselves* a nexus; we are not a privileged special-case inside it.

**Updating our cloud service ≠ updating the open standard.** Keep them in distinct commits/PRs and
state which one you're doing.

**Reducing an opinion to a standard (the ONLY allowed way it stays in the runtime).** Sometimes the
standard genuinely needs a new capability to fit our use case. Fine — but ship the **generic
primitive, never our values.** A pricing *mechanism* may live in the nexus IFF it is reduced to a
config-driven primitive the **DeployKit + reactor can supply**: tiers/limits declared in a `.work`
config block, read via `Nexus.Config`, nexus shipping neutral defaults — and *our* actual tiers are
then **our** DeployKit config, not constants in `lib/`. **The test for anything in the runtime:**
*could any user meet this contract with their own values, with none of ours baked in?* If no, it
belongs in our cloud app or our workbook, not the standard. (Tracked cleanup of existing violations —
Pricing/Upsell/Waitlist/reserved-host/image: bd `wb-n9ez`.)

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

### 🚨 NEVER leave a shell command running — always close it out 🚨

**This is critical: a lingering/background process freezes the machine.** Every command you start
MUST terminate on its own and you MUST confirm it exited before moving on.

- **Never** start a long-lived/daemon process (`iex -S mix`, `mix phx.server`, `bun run dev`, a
  watcher, a `tail -f`, a bare server) and walk away. If you must run one, bound it
  (`timeout <secs> …`) or stop it explicitly the moment you're done — do not let it dangle.
- When you run something in the background, **always close it out**: capture its PID/task id,
  wait for it to finish, and verify it's gone (no orphaned `iex`/`node`/`beam.smp`/watch process).
- Prefer one-shot, self-terminating commands (`mix test`, `mix compile`, a single `curl`) over
  anything that waits on a condition forever.
- Never use a foreground `sleep`-loop as a poll; if you must wait, bound it and let it exit.

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

A woven workbook's `client` islands render **client-side** — wasm in the browser, so it
runs everywhere (no kernel/engine provider). The `runtime` (nexus) backs `server` units,
agents, data, sync, and the compiler/weave lane.

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

### Verifying prod (wb-dogfood) — authenticated smoke

Don't ask for a PAT to test prod — one is already on disk from `work login`. Read it locally
(never the value in any committed file; the repo is public):

```bash
PAT=$(awk '{print $2}' ~/.work/credentials)   # "<nexus-url>\t<wbk_…>"
curl -s -H "authorization: Bearer $PAT" https://wb-dogfood.fly.dev/cloud/<route>
```

`~/.work/credentials` = `<url>\t<wbk_ PAT>`; `~/.config/workbooks/auth.json` = native session bearer +
email. To verify an auth gate, a protected route should return **403 anonymous** and **200 with the
Bearer PAT**. Adversarial + authenticated testing against prod is authorized.

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

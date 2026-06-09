# Desktop Engine Install Wizard — implementation plan

> Handoff doc for a fresh agent. You will NOT have the conversation that produced this; everything
> you need is here. Read it fully before coding.

## Goal (one line)
Add a first-run / on-demand **install wizard** to the desktop app that gets the **runtime engine
running locally inside a VM** (or connects to a cloud engine), so a freshly-downloaded app goes from
"offline-only" to "engine connected" without the user hand-running CLI commands.

## The architecture you are working within (do NOT change these — they are settled)
```
Desktop app  ──HTTP──>  Runtime (OCI image)  running INSIDE a VM   ── untrusted code → wasmtime sandbox
  (this repo,            (ghcr.io/workbooks-sh/runtime:latest,        (libkrun microVM on mac via the
   desktop/)             multi-arch, compilers baked in)               `Machine` backend; container in cloud)
```
- **Desktop and runtime ship SEPARATELY.** The desktop is its own signed/notarized release
  (`.github/workflows/desktop-release.yml`, tag `desktop-v*`). The runtime is the ghcr OCI image
  (`.github/workflows/runtime-image.yml`). They are NOT bundled together.
- **The runtime ALWAYS runs inside a VM.** This is core (isolation for untrusted code + local↔cloud
  parity via the same Linux image). Do NOT propose running the runtime natively / as a sidecar — that
  was explicitly rejected. Local = a **libkrun microVM** driven by `Workbooks.Deploy.Machine`
  (`runtime/host/deploy/machine.ex`, the `krunvm` tool is the mac backend). Cloud = same image as a
  container.
- **The desktop is offline-first.** It embeds `oql.wasm` and weaves workbooks locally with NO engine.
  The engine is OPTIONAL — the wizard must never block the app from opening. (See
  memory/spec: "desktop must boot WITHOUT the engine; show engine state in titlebar.")
- **Erlang note:** Erlang lives INSIDE the runtime image (a `mix release` ships its own ERTS). The
  user's machine does NOT need Erlang to *run* the engine — the VM/container has it. The only host
  dependency is the VM backend (krunvm/libkrun) + whatever boots it (see the open decision below).

## What already exists (do NOT rebuild)
- **`desktop/src-tauri/src/daemon.rs`** — the engine bridge, already working:
  - `status() -> DaemonStatus` — reads the runtime's discovery file + probes `/health`; returns
    running / stopped / unhealthy + a `chip` label for the titlebar. Short timeout, never stalls.
  - `daemon_up()` — if nothing live, runs `wb deploy local --json`, waits for the discovery file.
  - `daemon_down()` — `wb deploy down --json`.
  - `wb(args)` — shells to the `wb` escript, resolved from `WB_BIN` env or PATH.
  - Discovery file: written by the runtime inside the VM, read by the desktop → gives the URL
    (`http://localhost:<port>`).
- **Deploy-kit verbs** (`runtime/host/deploy.ex`): `wb deploy init local|cloud`, `wb deploy local`
  (boot the microVM), `status`, `down`, `url`. `Machine` (`runtime/host/deploy/machine.ex`) is the
  mac backend: ensure case-sensitive APFS volume → `krunvm create <image>` → `krunvm start` (launchd).
- **Runtime image**: `ghcr.io/workbooks-sh/runtime:latest` — PUBLIC, multi-arch (amd64+arm64),
  compilers baked in, verified to compile C/Rust in-sandbox. Pull needs no auth.
- **Frontend** (SvelteKit, `desktop/src/`): `routes/+page.svelte`, `+layout.svelte`,
  `lib/home/HomePanel.svelte`, `lib/chat/ChatPanel.svelte`, a status chip in the chrome. There is
  **no onboarding/wizard component yet** — you are adding it.

## What to build — the wizard
A wizard surface (modal or a dedicated route) that the user reaches from the engine status chip
("Engine: not connected → Set up") and on first run if no engine is configured. It must be
skippable (offline-first). State machine:

1. **Choose** — "Run the engine on this Mac" vs "Connect to a cloud engine."
2. **Cloud path** — input a URL + (optional) token → store it → `status()` against it → done.
3. **Local path** — the meat:
   a. **Detect the VM backend.** Is `krunvm` (and its libkrun dep) present? (and on non-mac, the
      platform equivalent — see cross-platform below.)
   b. **If missing → guide install.** Offer the one concrete install action for the platform
      (mac: `brew install krunvm` or the documented libkrun install; surface a button that runs it
      via a Tauri command, with a copy-paste fallback). Show progress + errors plainly.
   c. **Boot the engine** — call the existing `daemon_up()` path (which runs `wb deploy local` →
      `Machine` → pulls `runtime:latest`, boots the microVM). Stream status; first pull is slow
      (show a spinner + "downloading engine image, one time").
   d. **Connect** — poll `status()` until running; on `/health` 200, close the wizard, titlebar chip
      goes green.
4. **Failure surfaces** — every step shows the actual error + a retry, never a silent `let _ = wb(...)`.

## The one open implementation decision (pick + document your choice)
`daemon.rs` currently boots via the **`wb` escript** (`wb deploy local`), which needs the `wb` binary
(an Elixir escript → needs Erlang) on the host. On a fresh machine neither is present. Three ways to
resolve, in order of recommendation:

- **(A, recommended) Bundle the `wb` escript as a Tauri sidecar + have the wizard install only the VM
  backend.** Set `WB_BIN` to the bundled escript. Still needs Erlang on the host for the escript —
  so either bundle a minimal ERTS with it, or fold "install Erlang" into the wizard's prereq step.
- **(B) Skip `wb` entirely — boot the image directly from Rust.** The runtime image is self-contained
  (Erlang + compilers inside), so `krunvm create ghcr.io/workbooks-sh/runtime:latest` + `krunvm start`
  (port-map 4000, the APFS volume, the discovery bind-mount) is all you need — port the small
  `Machine` create/start/discovery logic to Rust in `daemon.rs`. No host Erlang at all. More Rust,
  but the lightest host footprint. **Strongly consider this** — it matches "user needs only the VM."
- **(C) Wizard installs `wb` + Erlang + krunvm as prereqs.** Simplest code, heaviest install.

Decide A vs B early; it shapes the local path. (B keeps the host to just the VM backend, which best
fits the settled design.)

## Cross-platform
The desktop builds mac/linux/windows. The VM backend differs per platform (mac: krunvm/libkrun;
linux: podman/native containers; windows: WSL2 + podman/docker). For v1, **fully implement the mac
path** (krunvm) and **stub linux/windows with a clear "local engine on this OS is coming; connect to
cloud for now" message** in the wizard — do not block those builds. The deploy-kit's backend seam
(`runtime/host/deploy/backend.ex`) is where additional local backends register later.

## Constraints / invariants (do not violate)
- Offline-first: the app must open and weave workbooks with the wizard never run / dismissed.
- The runtime runs in a VM — never natively, never bundled into the `.app`.
- Untrusted code only ever runs in wasmtime inside the runtime; the wizard touches none of that.
- Don't reimplement deploy logic the deploy-kit owns — drive it (or port the minimal `Machine`
  create/start if you pick B), keep one source of truth.

## Acceptance criteria
- Fresh Mac, app downloaded: open → works offline → run wizard → (installs krunvm if needed) → pulls
  `runtime:latest` → boots the microVM → titlebar chip goes green → a chat/agent action round-trips
  to the engine.
- Cloud path: paste a URL → connects → chip green.
- Wizard fully skippable; app never blocks on it.
- Every failure shows a real error + retry.
- Linux/Windows: wizard opens, offers the cloud path, clearly defers local-engine.

## Pointers
- Engine bridge: `desktop/src-tauri/src/daemon.rs`
- VM backend (mac): `runtime/host/deploy/machine.ex` (port create/start/discovery if going route B)
- Deploy verbs: `runtime/host/deploy.ex`, backend seam: `runtime/host/deploy/backend.ex`
- Frontend chrome / status chip: `desktop/src/lib/ui/chrome.svelte.ts`, `desktop/src/routes/+layout.svelte`
- Runtime image (public): `ghcr.io/workbooks-sh/runtime:latest`

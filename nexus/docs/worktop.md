# Worktop — the desktop-class deploy target

Worktop is a **generic deployment methodology** in the open `nexus` + `work` standard: a developer
packages *any* Nexus runtime to run locally as a desktop-class app — no VM, no container, fast — the
same way they'd `work deploy cloud`.

It is a **deploy target**, orthogonal to the front-end model. It changes *where* a Nexus runs, not
what it serves. It is on "the line": generic, unbranded, part of the standard — not a product, not a
UI, not the cloud control plane.

There are two packaging shapes:

1. **Burrito single binary** (this document, shipped): a self-contained `nexus` binary — a Zig-based
   Burrito wrapper over an OTP release — that boots a Nexus headless. Reactor-aligned: Burrito's
   wrapper is Zig-compiled, and the repo already ships a Zig reactor.
2. **Elixir Desktop windowing** (follow-up, not yet built): the BEAM owns a native WebView pointed at
   the embedded Nexus. See [Follow-ups](#follow-ups).

## How it works

`mix release worktop` assembles the ordinary `:nexus` OTP release (ERTS + BEAM + the app's
host-native NIFs) and then runs Burrito's wrap step, which:

- compiles a small Zig launcher for the host target,
- compresses the whole release into a payload embedded in that launcher,
- emits **one** self-contained executable: `burrito_out/worktop_host`.

On first run the binary unpacks its bundled ERTS to a per-user cache
(`~/Library/Application Support/.burrito/…` on macOS) and executes the release. No system Erlang,
Elixir, or Rust is required on the target machine — everything is inside the binary.

The served Nexus is identical to any other: it honors the same env-injected machine identity
(`PORT`, `WB_DATA`) and serving gate (`WB_SERVE=1`) as the cloud/vfkit runtimes, so a workbook behaves
the same locally as it does deployed. No JSON config, no per-target code — deploy config stays in the
`.work` `deploy` block and `Nexus.Config`.

## Build it

From the runtime (the `nexus/` mix project):

```bash
# Burrito requires its pinned Zig (0.15.2) and xz in PATH. See the caveats below —
# the repo's Zig reactor uses a different Zig, so install 0.15.2 side-by-side and
# prepend it to PATH for this build only.
MIX_ENV=prod mix release worktop
# -> _build/prod/rel/worktop assembled, then wrapped to:
#    burrito_out/worktop_host   (a self-contained host binary)
```

Or via the `work` reactor (which invokes the same `mix release worktop`):

```bash
work deploy init desktop .     # scaffolds a deployment.work with engine-place="desktop"
work deploy validate           # coherence check (desktop must be single-user)
work deploy apply              # builds burrito_out/worktop_host
```

The base `:nexus` release (the Linux OCI image entrypoint) is unchanged — `mix release nexus` still
targets `:unix` for the vfkit/Fly image.

## Run it

The binary boots a Nexus headless. Machine identity comes from the environment (the only allowed use
of env — everything else is `.work` + `Nexus.Config`):

```bash
WB_SERVE=1 PORT=51491 WB_DATA=/tmp/worktop-data ./burrito_out/worktop_host start
# In another shell:
curl -s localhost:51491/health
# {"status":"ok","service":"nexus","version":"0.1.0","nexus":"gentle-narwhal-87","friendly":""}
```

A deployed release sets `RELEASE_NAME`, which puts the app in its fail-closed posture: it refuses to
boot without a strong `WB_SESSION_SECRET` (≥ 16 bytes). Set one for a real Worktop deployment:

```bash
WB_SESSION_SECRET=$(openssl rand -hex 32) WB_SERVE=1 PORT=51491 WB_DATA=/tmp/worktop-data \
  ./burrito_out/worktop_host start
```

## Verified (macOS aarch64, this MVP)

Built and booted through the real production path:

- `MIX_ENV=prod mix release nexus` → assembles; NIFs bundled
  (`exqlite/priv/sqlite3_nif.so`, `wasmex/priv/native/wasmex.so`, crypto, asn1).
- `MIX_ENV=prod mix release worktop` → `burrito_out/worktop_host` = a 20 MB
  `Mach-O 64-bit executable arm64`, fully self-contained.
- `./burrito_out/worktop_host start` (with `WB_SERVE=1`) → `GET /health` returns **HTTP 200**:
  `{"status":"ok","service":"nexus","version":"0.1.0","nexus":"gentle-narwhal-87","friendly":""}`.
- The binary's unpack dir contains its own `erts-16.2.1/bin/beam.smp` **and** both NIFs
  (`sqlite3_nif.so`, `wasmex.so`) — confirming NIF bundling works for the host arch.

## Trust & isolation (read this)

Worktop is **inherently trusted, single-user, and local.**

A served Nexus runs native units — `server`, `worker`, `def`, `hook`, `auth` — directly on the BEAM.
Those native units **cannot be contained in-process**: the trust boundary is the machine. So a Worktop
binary is only appropriate for a workbook *you* trust, running as *you*, on *your* machine.

- **Trusted / your own workbooks → Worktop.** One host process, single user, full speed.
- **Untrusted / third-party Nexuses → still the vfkit microVM** (`work deploy local`). That's the
  isolation boundary for code you don't trust; Worktop does not and should not try to sandbox native
  units.

The go-forward *in-process* sandbox for untrusted **guest** code (compiled to WebAssembly) remains
"tiny lasers" (BEAM-native, `Nexus.Washy`). Worktop changes nothing there — it just packages the
whole trusted runtime as a binary. This is enforced in config: `work deploy validate` rejects
`tenancy-mode="multi"` on `engine-place="desktop"` (a single host process can't isolate tenants).

## Caveats & the target matrix

- **Zig pin.** Burrito 1.5.0 hard-requires **Zig 0.15.2** and refuses any other version. The repo's
  `work` reactor builds with a different Zig (0.16.x). Keep them side-by-side: install 0.15.2 to its
  own dir and prepend it to `PATH` only for `mix release worktop`. Do **not** replace the reactor's
  Zig. (A newer Burrito that supports 0.16 would remove this friction.)
- **`xz` required**, and `7z` is required only for Windows targets (not needed for macOS/Linux).
- **Host arch only, for now.** The `:worktop` release derives its Burrito target from the *build
  machine's* architecture (`host_os/0` + `host_cpu/0` in `mix.exs`). NIFs are host-native, so the
  binary runs on the arch that built it. Cross-target builds are follow-up (see below).
- **NIFs.**
  - `exqlite` — a C NIF (`sqlite3_nif.so`), compiled for the host at `mix compile`. Bundles + loads
    cleanly.
  - `wasmex` — a **vendored, patched** Rust NIF built *from source* (`force_build: true`, so it links
    wasmtime). Building the release therefore needs a Rust toolchain (`cargo`) on the *build* machine;
    the resulting `wasmex.so` is bundled and loads on the same host. wasmex is being deprecated in
    favor of tiny-lasers, but while it's still in `extra_applications` its NIF ships in the binary and
    is the heaviest part of the build. The *target* machine needs neither Rust nor wasmtime — only the
    build machine does.
- **Unpack cache.** First run unpacks ERTS to `~/Library/Application Support/.burrito/…` (macOS) /
  the XDG data dir (Linux). Delete it to force a fresh unpack; the maintenance verbs on the binary
  manage it.

## Follow-ups

- **Cross-platform matrix.** Extend the `:worktop` release's `burrito: [targets: …]` map to build
  Linux (x86_64/aarch64) and Windows (x86_64) binaries. Cross-target NIFs are the hard part:
  `exqlite` can cross-compile via its C toolchain, but the vendored `wasmex` (`force_build`) needs a
  cross Rust toolchain per target — or a precompiled path. Track this as its own effort.
- **Elixir Desktop windowing.** Wrap the embedded Nexus in a native window: the BEAM owns a WebView
  pointed at `localhost:<port>` served by this same headless runtime. Purely additive on top of the
  Burrito binary — the runtime doesn't change, only the shell around it.
- **Burrito ↔ Zig 0.16.** Revisit when Burrito supports the reactor's Zig so one toolchain covers
  both the reactor and the Worktop wrap.

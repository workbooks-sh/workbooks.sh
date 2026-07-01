defmodule Nexus.MixProject do
  use Mix.Project

  def project do
    [
      app: :nexus,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: ["lib"],
      # Allow an isolated _build via WB_BUILD_PATH so a long background job (e.g. the full 53k-case
      # test262 run) compiles+runs in its own build dir and never collides with foreground `mix` on the
      # default _build. Unset → "_build" (no behavior change).
      build_path: System.get_env("WB_BUILD_PATH", "_build"),
      deps: deps(),
      releases: releases()
    ]
  end

  # `mod:` boots Nexus.Application (an empty supervision tree) so the release's
  # `Application.ensure_all_started(:nexus)` boot expr (Nexus.Deploy.Machine.start_argv/1) succeeds
  # and parks the node alive. wasmex must be in extra_applications so its NIF loads in the release.
  def application do
    [
      extra_applications: [:logger, :wasmex],
      mod: {Nexus.Application, []}
    ]
  end

  # The :nexus release — `mix release` emits _build/prod/rel/nexus/bin/nexus, the OCI image's
  # entrypoint (`/app/bin/nexus eval …`). include_executables_for: [:unix] keeps it Linux-targeted
  # (the krunvm guest is Linux); the BEAM + ERTS are bundled so the runtime image needs no Elixir.
  #
  # The :worktop release — the generic desktop-class DEPLOY TARGET (`work deploy desktop`). Same app,
  # same serving contract, but Burrito wraps the assembled OTP release (ERTS + BEAM + host-native NIFs)
  # into ONE self-contained `nexus` binary that boots a Nexus headless with no VM/container. Burrito's
  # wrapper is Zig-compiled (reactor-aligned; the repo already ships a Zig reactor). It targets the
  # HOST arch only in this MVP — see `host_os/0` + `host_cpu/0`. Worktop is inherently TRUSTED and
  # single-user/local: native server/worker/def/hook/auth units can't be sandboxed in-process ("the
  # trust boundary is the machine"), so untrusted third-party Nexuses still need the vfkit microVM.
  defp releases do
    [
      nexus: [
        include_executables_for: [:unix],
        applications: [nexus: :permanent]
      ],
      worktop: [
        applications: [nexus: :permanent],
        # Burrito wrap runs at BUILD time (a release step); the assembled release is identical to
        # `nexus`'s, so the host-native NIFs (exqlite C NIF + the vendored wasmex Rust NIF, both built
        # for the host during `mix compile`) are bundled as-is and load from Burrito's unpack dir.
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            host: [os: host_os(), cpu: host_cpu()]
          ]
        ]
      ]
    ]
  end

  # Host OS/CPU for the Burrito target map (Burrito wants :darwin/:linux/:windows + :aarch64/:x86_64).
  # MVP builds for the HOST only — cross-target (the full matrix) is follow-up. Derived from the BEAM's
  # own system architecture so the wrapped binary matches the machine that built its NIFs.
  defp host_os do
    case :os.type() do
      {:unix, :darwin} -> :darwin
      {:win32, _} -> :windows
      _ -> :linux
    end
  end

  defp host_cpu do
    arch = List.to_string(:erlang.system_info(:system_architecture))
    cond do
      String.contains?(arch, "aarch64") or String.contains?(arch, "arm64") -> :aarch64
      true -> :x86_64
    end
  end

  # The sandbox is wasmex (wasmtime + component model). The data base is a typed struct + the
  # pluggable `Nexus.Store` seam (ETS default; Postgres/SQLite/wasm-SQL behind the same interface)
  # — NOT a framework. (Ash can return later as one optional store adapter, not the foundation.)
  defp deps do
    [
      # the shared `.work` literate toolchain (parse/graph/extract/wit/weave) — one home, no dup
      {:wasmex, path: "vendor/wasmex"},
      # durable-local store backend behind the Nexus.Store seam (precompiled NIF). The cloud
      # backend (Neon Postgres) and any wasm-SQL engine slot in behind the same 4 callbacks.
      {:exqlite, "~> 0.23"},
      # the served-nexus HTTP tier: SSR the workbook + the /data API the client nexus.data falls to.
      {:bandit, "~> 1.5"},
      # JSON at the genuine boundaries (HTTP API responses, Fly/WorkOS payloads). Used DIRECTLY, so it
      # must be a direct dep — as an optional-transitive (via ecto) it compiled in dev/test but `mix
      # release` excluded it → `Jason is not available` 500s in prod. (Caught on the first deploy.)
      {:jason, "~> 1.4"},
      # JWT verification for the auth seam (HS256 secret + RS256/JWKS — WorkOS/Clerk/Auth0/own).
      {:jose, "~> 1.11"},
      # pure-Elixir HTML parser (mochiweb backend, no NIF) — the cheap no-wasm read rung: extract
      # text/links/markdown in the BEAM, escalating to the Blitz wasm render only when thin.
      {:floki, "~> 0.36"},
      # Worktop packager: wraps the assembled OTP release into ONE self-contained host binary (Zig
      # launcher, reactor-aligned). Build-time only (`runtime: false`) — it's a `mix release` step, not
      # a runtime app, so it never ships inside the release itself.
      {:burrito, "~> 1.5", runtime: false}
    ]
  end
end

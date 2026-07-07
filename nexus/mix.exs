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
  defp releases do
    [
      nexus: [
        include_executables_for: [:unix],
        applications: [nexus: :permanent]
      ]
    ]
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
      # the WASM→BEAM execution substrate (was Nexus.Washy, extracted + hardened). Vendor-back:
      # nexus consumes it and retires its stale in-tree copy. Keys are :tl_*/:gg_* (disjoint from
      # the legacy :washy_* pdict/ETS keys), so both can coexist during the phased cutover.
      {:tiny_lasers, path: "../tiny-lasers"},
      # dependency CVE scanner (advisory DB) — dev/test only, never shipped. `mix deps.audit`.
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end
end

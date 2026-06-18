defmodule Nexus.MixProject do
  use Mix.Project

  def project do
    [
      app: :nexus,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: ["lib"],
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  # The sandbox is wasmex (wasmtime + component model). The data base is a typed struct + the
  # pluggable `Nexus.Store` seam (ETS default; Postgres/SQLite/wasm-SQL behind the same interface)
  # — NOT a framework. (Ash can return later as one optional store adapter, not the foundation.)
  defp deps do
    [
      {:wasmex, path: "../runtime/vendor/wasmex"},
      # durable-local store backend behind the Nexus.Store seam (precompiled NIF). The cloud
      # backend (Neon Postgres) and any wasm-SQL engine slot in behind the same 4 callbacks.
      {:exqlite, "~> 0.23"}
    ]
  end
end

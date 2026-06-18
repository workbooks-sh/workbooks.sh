defmodule WorkCore.MixProject do
  use Mix.Project

  # The shared `.work` literate toolchain — parse, code graph, capability catalog, WIT generation,
  # extractors, weave. PURE Elixir: no wasmex NIF, no server, no network. Consumed by both `nexus`
  # (the engine) and `work` (the CLI), so the toolchain has exactly ONE home.
  def project do
    [
      app: :work_core,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: ["lib"],
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  # Floki (HTML parse for weave) + Jason are the only deps; nothing that pulls a NIF.
  defp deps do
    []
  end
end

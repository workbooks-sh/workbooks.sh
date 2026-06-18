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

  # Deps land as each layer is built, not up front:
  #   {:ash, "~> 3.0"}             — when the data layer lands (resources ARE Ash resources)
  #   {:wasmex, path: "..."}       — when the sandbox lands (run wasm components)
  # The authoring + contract layers (Literate/Resource/Wit/Dock) are pure Elixir — no deps.
  defp deps, do: []
end

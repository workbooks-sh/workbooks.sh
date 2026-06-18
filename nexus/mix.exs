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

  # The sandbox is wasmex (wasmtime + component model); the database is Ash (a resource IS an
  # Ash resource). Both reused, not rebuilt — nexus drives them.
  defp deps do
    [
      {:wasmex, path: "../runtime/vendor/wasmex"},
      {:ash, "~> 3.0"}
    ]
  end
end

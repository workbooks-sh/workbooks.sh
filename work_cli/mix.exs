defmodule WorkCLI.MixProject do
  use Mix.Project

  # `work` — the universal ecosystem CLI (a sibling to nexus, not inside it). A thin escript over
  # the shared `work_core` toolchain for local ops, and an HTTP/RCP client to a nexus / control plane
  # for engine ops. Cold-starts fast; carries no server/NIF.
  def project do
    [
      app: :work_cli,
      version: "0.1.0",
      elixir: "~> 1.17",
      escript: [main_module: WorkCLI.Main, name: "work"],
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger, :inets, :ssl]]

  defp deps do
    [
      {:work_core, path: "../work_core"},
      {:jason, "~> 1.4"}
    ]
  end
end

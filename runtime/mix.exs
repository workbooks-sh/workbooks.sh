defmodule Workbooks.MixProject do
  use Mix.Project

  # The whole system. Elixir host in host/, OQL kernel (Rust) in kernel/,
  # compiled wasm in build/. No lib/, no priv/, no app-name nesting.
  def project do
    [
      app: :workbooks,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: ["host"],
      escript: [main_module: Workbooks.CLI, name: "wb"],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Workbooks.Application, []}
    ]
  end

  defp deps do
    [
      {:wasmex, "~> 0.14"},
      {:exqlite, "~> 0.27"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:websock_adapter, "~> 0.5"},
      {:guardian, "~> 2.3"},
      {:jose, "~> 1.11"},
      {:postgrex, "~> 0.19"}
    ]
  end
end

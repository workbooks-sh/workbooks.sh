defmodule Workbooks.MixProject do
  use Mix.Project

  # The whole system. Elixir host in host/, OQL kernel (Rust) in kernel/,
  # compiled wasm in build/. No lib/, no priv/, no app-name nesting.
  def project do
    [
      app: :workbooks,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: ["test"],
      escript: [main_module: Workbooks.CLI, name: "wb"],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # No lib/. Host code lives in host/. The in-BEAM ML adapter lives in host_ml/ and
  # is compiled ONLY when WB_BUMBLEBEE=1 (it references Bumblebee directly), so the
  # default build needs neither the dir nor the dep. The registry routes to it at
  # runtime via Code.ensure_loaded?, so host/ compiles without it either way.
  defp elixirc_paths(_) do
    base = ["host"]
    if System.get_env("WB_BUMBLEBEE") == "1", do: base ++ ["host_ml"], else: base
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
    ] ++ ml_deps()
  end

  # In-BEAM neural embedder (CLIP image+text via Bumblebee + EXLA, served with
  # Nx.Serving batching). HEAVY (pulls XLA), so OPT-IN at build time —
  # `WB_BUMBLEBEE=1 mix release`. Default builds stay lean (text = Model2Vec,
  # no EXLA); the standalone CLIP sidecar remains the no-NIF alternative.
  defp ml_deps do
    if System.get_env("WB_BUMBLEBEE") == "1" do
      [{:bumblebee, "~> 0.6"}, {:exla, "~> 0.9"}, {:nx, "~> 0.9"}, {:stb_image, "~> 0.6"}]
    else
      []
    end
  end
end

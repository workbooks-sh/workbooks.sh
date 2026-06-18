defmodule Workbooks.MixProject do
  use Mix.Project

  # The whole system. Elixir host in host/. A workbook is an HTML file built from
  # `work-*` web components; the backend reads its structure with Floki, not a
  # bespoke kernel. No lib/, no priv/, no app-name nesting.
  def project do
    [
      app: :workbooks,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: ["test"],
      # app: nil → the escript does NOT auto-start :workbooks (which would load the
      # wasmex NIF, impossible from an escript archive). CLI.main starts the app
      # itself only for verbs that need the runtime; `work deploy` stays NIF-free.
      escript: [main_module: Workbooks.CLI, name: "work", app: nil],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # No lib/. Host code lives in host/. The in-BEAM ML adapter lives in host_ml/ and
  # is compiled ONLY when WB_CLIP=1 (it references Ortex/Tokenizers directly), so the
  # default build needs neither the dir nor the dep. The registry routes to it at
  # runtime via Code.ensure_loaded?, so host/ compiles without it either way.
  defp elixirc_paths(_) do
    base = ["host"]
    base = if System.get_env("WB_CLIP") == "1", do: base ++ ["host_ml"], else: base
    # Features (video/wavelet, …) live OUTSIDE the core compile, no flag — canon: features
    # are loaded toolkits, not host engines. They sit parked under features/ awaiting
    # WIT-component conversion; the core never compiles them. (Structure over flags.)
    base
  end

  def application do
    [
      # :inets/:ssl back the pure-Erlang crate fetch (:httpc) that replaced the curl/tar binaries
      # (wb-ova) — no external process in the compile path; TLS verified via OTP cacerts.
      extra_applications: [:logger, :inets, :ssl],
      mod: {Workbooks.Application, []}
    ]
  end

  defp deps do
    [
      # wb-v3d: vendored, patched wasmex (engine.rs enables the wasm exception proposal so
      # mrustc_pm.wasm runs proc-macro expansion under Wasmex). Committed source, always built from
      # source (force_build) — durable: no deps.get reversion, no env var, no external fork.
      {:wasmex, path: "vendor/wasmex"},
      {:exqlite, "~> 0.27"},
      # Ash = the server-side database engine for the literate `resource` model
      # (docs/DATA-LAYER-DECISION.md). Authors never see it; the resource compiler emits it.
      {:ash, "~> 3.0"},
      {:floki, "~> 0.36"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:websock_adapter, "~> 0.5"},
      {:guardian, "~> 2.3"},
      {:jose, "~> 1.11"},
      {:postgrex, "~> 0.19"}
    ] ++ ml_deps()
  end

  # In-BEAM CLIP image+text embedder — ONNX via Ortex (onnxruntime, ~20 MB) + the
  # HF tokenizer + q8 CLIP towers (~147 MB). LIGHT vs EXLA/XLA (~900 MB), no JIT.
  # OPT-IN at build — `WB_CLIP=1 mix release` — so default builds stay lean (text =
  # Model2Vec, no native ML at all). Runtime route: WB_EMBED=clip.
  defp ml_deps do
    if System.get_env("WB_CLIP") == "1" do
      [{:ortex, "~> 0.1.10"}, {:tokenizers, "~> 0.5"}, {:nx, "~> 0.9"}, {:stb_image, "~> 0.6"}]
    else
      []
    end
  end
end

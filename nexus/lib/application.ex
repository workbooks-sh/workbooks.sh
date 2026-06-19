defmodule Nexus.Application do
  @moduledoc """
  OTP application root for the nexus release.

  `Nexus.Deploy.Machine` boots the microVM with `/app/bin/nexus eval "Application.ensure_all_started(
  :nexus) … Process.sleep(:infinity)"` (and the release's `bin/nexus start`), so `:nexus` must START
  and keep a live tree. Beyond the pure pipelines (Literate → Compile → Sandbox → Weave), in a
  **serving** context (a release, or `WB_SERVE`/`WB_DESKTOP` set) it also brings up `Nexus.Server`
  (the HTTP tier, incl. `/health`) and publishes the desktop discovery file — so a deployed/local
  nexus actually answers on its port. `mix test` is NOT a serving context (no port binding).
  """
  use Application

  @impl true
  def start(_type, _args) do
    # Load runtime config from the deployment's <work-deploy> element (HTML source of truth) into
    # :persistent_term BEFORE the Gate reads its concurrency limit. No env vars for tunable config.
    Nexus.Config.boot()
    # Register the selected `:search` provider behind the Nexus.Browse seam. Default = keyless
    # metasearch (pure-BEAM, local/dev); `<work-deploy search="brave">` swaps in the keyed cloud API.
    register_search_provider()
    # In the control-plane role, force WorkOS-JWT auth (org_id → tenant) from the deploy env — every
    # /api/platform caller must carry a real org identity (fail-closed; see Nexus.ControlPlane).
    Nexus.ControlPlane.configure_auth()
    # Empty by default; Constellation's local-inference lanes opt in via `config :nexus, Nexus.Constellation, enabled: true`.
    ether = if Nexus.Constellation.enabled?(), do: Nexus.Constellation.children(), else: []
    # Nexus.Wasm.Gate bounds concurrent wasm OS processes per lane (compile-concurrency /
    # render-concurrency) so a burst can't fork-bomb wasmtime into an OOM — backpressure instead.
    children =
      [Nexus.Telemetry, Nexus.ControlPlane.Store] ++
        Nexus.Wasm.Gate.child_specs() ++ Nexus.Cache.child_specs() ++ ether ++ server_children()
    result = Supervisor.start_link(children, strategy: :one_for_one, name: Nexus.Supervisor)

    # Once the server is up, publish the desktop discovery file (no-op unless WB_DESKTOP_DIR is set).
    if serve?(), do: Nexus.Desktop.write_discovery(port())
    result
  end

  # Serve when we're a deployed runtime (a release sets RELEASE_NAME) or explicitly told to
  # (WB_SERVE / WB_DESKTOP — the desktop injects WB_DESKTOP=1). `mix test` matches none → no listener.
  defp serve? do
    System.get_env("RELEASE_NAME") != nil or
      System.get_env("WB_SERVE") in ~w(1 true) or
      System.get_env("WB_DESKTOP") in ~w(1 true)
  end

  defp server_children do
    if serve?(), do: [{Nexus.Server, root: root(), port: port()}], else: []
  end

  # PORT + WB_DATA are deploy injection (the orchestrator sets the port + the volume mount), like
  # WB_DATA elsewhere — infrastructure, not authored config.
  # Select + register the configured `:search` provider (keyless metasearch is the safe default).
  defp register_search_provider do
    mod =
      case Nexus.Config.search() do
        "brave" -> Nexus.Browse.Search.Brave
        "metasearch" -> Nexus.Browse.Search.Metasearch
        _ -> Nexus.Browse.Search.Metasearch
      end

    Nexus.Browse.register(mod)
  end

  defp port, do: String.to_integer(System.get_env("PORT") || "4000")
  defp root, do: System.get_env("WB_DATA") || File.cwd!()
end

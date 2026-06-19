defmodule Nexus.Application do
  @moduledoc """
  Minimal OTP application root for the nexus release.

  `Nexus.Deploy.Machine` boots the microVM with
  `/app/bin/nexus eval "Application.ensure_all_started(:nexus) … Process.sleep(:infinity)"`,
  so `:nexus` must START successfully and keep a live supervision tree. nexus is a library of
  pure pipelines (Literate → Compile → Sandbox → Weave) with no long-lived processes of its own
  yet, so the tree is intentionally empty — it exists purely to make `ensure_all_started/1`
  return `{:ok, _}`. Add children (a control-plane HTTP listener, a store supervisor, …) here as
  the runtime grows a server surface.
  """
  use Application

  @impl true
  def start(_type, _args) do
    # Load runtime config from the deployment's <work-deploy> element (HTML source of truth) into
    # :persistent_term BEFORE the Gate reads its concurrency limit. No env vars for tunable config.
    Nexus.Config.boot()
    # Empty by default; Constellation's local-inference lanes opt in via `config :nexus, Nexus.Constellation, enabled: true`.
    ether = if Nexus.Constellation.enabled?(), do: Nexus.Constellation.children(), else: []
    # Nexus.Wasm.Gate bounds concurrent wasm OS processes per lane (compile-concurrency /
    # render-concurrency) so a burst can't fork-bomb wasmtime into an OOM — backpressure instead.
    children = [Nexus.Telemetry] ++ Nexus.Wasm.Gate.child_specs() ++ ether
    Supervisor.start_link(children, strategy: :one_for_one, name: Nexus.Supervisor)
  end
end

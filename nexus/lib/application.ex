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
    # Empty by default; Ether's local-inference lanes opt in via `config :nexus, Nexus.Ether, enabled: true`.
    ether = if Nexus.Ether.enabled?(), do: Nexus.Ether.children(), else: []
    children = [Nexus.Telemetry | ether]
    Supervisor.start_link(children, strategy: :one_for_one, name: Nexus.Supervisor)
  end
end

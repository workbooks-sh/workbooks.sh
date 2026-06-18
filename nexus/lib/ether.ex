defmodule Nexus.Ether do
  @moduledoc """
  Ether — local two-brain inference, scheduled from nexus.

  **Experimental, OFF by default.** OpenRouter stays the primary LLM path; Ether is an opt-in lane
  that routes a turn to a *local* model server instead. Enable per app env:

      config :nexus, Nexus.Ether,
        enabled: true,
        cpu: [base_url: "http://127.0.0.1:8081/v1/chat/completions", model: "granite-4.1-3b"],
        gpu: [base_url: "http://127.0.0.1:8084/v1/chat/completions", model: "gemma-4-12b"]

  Two lanes by **resource shape** (see `Nexus.Ether.Lane`): a parallel CPU lane (autoregressive,
  many agents at once) and a serial GPU lane (diffusion, one full-GPU run at a time). `route/1` maps
  a task type to a lane; `run/3` submits the turn to that lane's scheduler and calls the local model
  via `Nexus.Llm.complete/2` with the lane's `base_url`. Spec-coupling (diffusion drafts, AR verifies)
  is a later layer that plugs into these same lanes — the router comes first.
  """
  alias Nexus.{Llm, Ether.Lane}

  @cpu Nexus.Ether.CPU
  @gpu Nexus.Ether.GPU

  @doc "True when the local lanes are enabled (else callers should fall back to OpenRouter)."
  def enabled?, do: cfg(:enabled, false)

  @doc "Recommended lane config for this machine (cores/memory/GPU). See `Nexus.Ether.Tier`."
  def tier, do: Nexus.Ether.Tier.recommend()

  @doc """
  Which lane a task type belongs to. GPU lane = the full-GPU diffusion jobs (fast parallel-block
  work: drafting, infill, inline edits, classification/routing). CPU lane = everything else
  (orchestration, tool loops, chat) — the default.
  """
  def route(type) when type in [:draft, :infill, :edit, :classify, :route], do: :gpu
  def route(_), do: :cpu

  @doc "Lane for an untagged free-text prompt. See `Nexus.Ether.Router`."
  defdelegate classify(text), to: Nexus.Ether.Router

  @doc """
  Run one local completion turn for `type`. The base lane comes from `route/1`, then
  `Nexus.Ether.Router.dispatch/2` may spill a backed-up GPU job to an idle CPU lane.
  Returns `Nexus.Llm.complete/2` shape.
  """
  def run(type, messages, opts \\ []) do
    lane = Nexus.Ether.Router.dispatch(type, route(type))
    GenServer.whereis(lane_name(lane)) || raise "Nexus.Ether not started (enabled: true?)"
    Lane.submit(lane_name(lane), fn -> Llm.complete(messages, Keyword.merge(lane_opts(lane), opts)) end)
  end

  @doc "Supervisor children — added by `Nexus.Application` only when `enabled?/0`."
  def children do
    [
      {Task.Supervisor, name: Nexus.Ether.Tasks},
      Supervisor.child_spec({Lane, name: @cpu, slots: cpu_slots()}, id: @cpu),
      Supervisor.child_spec({Lane, name: @gpu, slots: 1}, id: @gpu)
    ]
  end

  # CPU lane width = perf-ish cores, leaving headroom for the OS/orchestrator.
  def cpu_slots, do: max(1, System.schedulers_online() - 2)

  defp lane_name(:cpu), do: @cpu
  defp lane_name(:gpu), do: @gpu

  # base_url/model for a lane, with loopback defaults matching the ether/spike serve scripts.
  defp lane_opts(:cpu),
    do: Keyword.merge([base_url: "http://127.0.0.1:8081/v1/chat/completions"], cfg(:cpu, []))

  defp lane_opts(:gpu),
    do: Keyword.merge([base_url: "http://127.0.0.1:8084/v1/chat/completions"], cfg(:gpu, []))

  defp cfg(key, default), do: Keyword.get(Application.get_env(:nexus, __MODULE__, []), key, default)
end

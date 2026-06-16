defmodule Workbooks.AgentStream do
  @moduledoc """
  Live agent telemetry over a WebSocket (`GET /api/run/:id/stream`) — brandnana's
  per-step event stream. On connect it subscribes to the AgentSession; each tool
  step the agent takes is pushed as a JSON frame the moment it happens, then a
  final `done` frame. The same observable trace is also durable in events.html.
  """
  @behaviour WebSock

  @impl true
  def init(%{id: id} = state) do
    case Workbooks.AgentSession.subscribe(id) do
      :ok -> {:push, {:text, frame(%{type: "subscribed", id: id})}, state}
      :not_found -> {:push, {:text, frame(%{type: "error", error: "no such run"})}, state}
    end
  end

  @impl true
  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({:agent_step, ev}, state) do
    {:push, {:text, frame(%{type: "step", step: ev.step, tool: ev.tool, output: String.slice(ev.output, 0, 500)})}, state}
  end

  # Token-by-token text deltas as the model generates the reply (wb-2s09 /
  # streaming). The client appends these to the in-progress assistant message,
  # then reconciles against the final `done` result.
  def handle_info({:agent_delta, chunk}, state) do
    {:push, {:text, frame(%{type: "delta", content: chunk})}, state}
  end

  def handle_info({:agent_done, result}, state) do
    {:push, {:text, frame(%{type: "done", result: result})}, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  defp frame(map), do: Jason.encode!(map)
end

defmodule Workbooks.PhoenixSocket do
  @moduledoc """
  Minimal Phoenix-Channels-v2-compatible socket for the desktop bridge (wb-e95f).

  The desktop's ws.svelte connects with the Phoenix JS client and multiplexes
  several topics over one socket — `session:*`, `runtime:telemetry`,
  `desktop:control`, `workgate:control`, `engine:env_prompt`. This runtime had
  no `/socket`, so the client reconnect-looped and the channel features
  (telemetry fan-out, agent tab-control, env-approval) were dead.

  This handler accepts the connection and ACKs every join + heartbeat so the
  bridge connects cleanly and stays alive. Channel PAYLOADS (pushing telemetry,
  receiving tab-control) are layered on top later via Phoenix.PubSub; for now
  inbound events are acked and nothing is pushed — which is exactly the
  "connected, quiet" state the desktop expects from an idle engine.

  Phoenix v2 wire format — each text frame is a JSON array:
      [join_ref, ref, topic, event, payload]
  and a server reply is:
      [join_ref, ref, topic, "phx_reply", %{"status" => "ok", "response" => %{}}]
  Heartbeats arrive as [null, ref, "phoenix", "heartbeat", {}] and are acked the
  same way (join_ref null).
  """
  @behaviour WebSock

  require Logger

  @impl true
  def init(state) do
    # Subscribe to the runtime telemetry firehose so future pushes can fan out
    # here without re-architecting; harmless if the PubSub topic is unused.
    {:ok, state}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, [join_ref, ref, topic, event, _payload]} ->
        {:push, {:text, ack(join_ref, ref, topic)}, maybe_track(event, topic, join_ref, state)}

      _ ->
        {:ok, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  # Telemetry / control pushes arrive as Erlang messages (Phoenix.PubSub or a
  # direct send) and are forwarded as channel events. None are wired yet, so this
  # is a quiet no-op until the channel features land.
  @impl true
  def handle_info({:channel_push, join_ref, topic, event, payload}, state) do
    frame = Jason.encode!([join_ref, nil, topic, event, payload])
    {:push, {:text, frame}, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # A phx_reply ok for any join/heartbeat/leave/push.
  defp ack(join_ref, ref, topic) do
    Jason.encode!([join_ref, ref, topic, "phx_reply", %{"status" => "ok", "response" => %{}}])
  end

  # Remember the join_ref per topic so future server-initiated pushes address the
  # right channel instance. (Inbound leaves drop it.) For desktop:control we also
  # register in the DesktopControl registry — that's how an agent's `wb desktop`
  # push finds this connected shell.
  defp maybe_track("phx_join", topic, join_ref, state) do
    if topic == "desktop:control", do: Workbooks.DesktopControl.register(join_ref)
    Map.update(state, :topics, %{topic => join_ref}, &Map.put(&1, topic, join_ref))
  end

  defp maybe_track("phx_leave", topic, _join_ref, state) do
    Map.update(state, :topics, %{}, &Map.delete(&1, topic))
  end

  defp maybe_track(_event, _topic, _join_ref, state), do: state
end

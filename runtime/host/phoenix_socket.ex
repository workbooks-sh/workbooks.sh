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
  # direct send) and are forwarded as channel events.
  @impl true
  def handle_info({:channel_push, join_ref, topic, event, payload}, state) do
    frame = Jason.encode!([join_ref, nil, topic, event, payload])
    {:push, {:text, frame}, state}
  end

  # ── Session bridge (wb-2s09 / streaming) ────────────────────────────────────
  # When the desktop joins `session:<id>` we subscribe to the matching
  # AgentSession; its run events arrive here as Erlang messages and we translate
  # them into the Phoenix-channel events session.svelte already projects
  # (session_started / llm_turn_start / llm_delta / llm_turn_stop /
  # tool_call_*). Without this the desktop's chat channel was joined-but-silent.
  def handle_info({:bridge_session_started, topic, jr}, state) do
    {:push, {:text, push_frame(jr, topic, "session_started", %{"agent" => %{"name" => "Waldo"}})}, state}
  end

  def handle_info({:agent_step, ev}, %{session: %{topic: topic, join_ref: jr}} = state) do
    tcid = "s#{ev.step}"
    start = push_frame(jr, topic, "tool_call_start", %{"metadata" => %{"tool_name" => ev.tool, "tool_call_id" => tcid, "args" => ev.args}})

    stop =
      push_frame(jr, topic, "tool_call_stop", %{
        "metadata" => %{"tool_call_id" => tcid, "status" => if(ev.error, do: "error", else: "ok"), "result_size" => byte_size(ev.output || "")}
      })

    {:push, [{:text, start}, {:text, stop}], state}
  end

  def handle_info({:agent_delta, chunk}, %{session: %{topic: topic, join_ref: jr, turn: turn}} = state) do
    # The first delta of a text turn opens an assistant message; the rest append.
    start = if turn, do: [], else: [{:text, push_frame(jr, topic, "llm_turn_start", %{"metadata" => %{}})}]
    delta = {:text, push_frame(jr, topic, "llm_delta", %{"metadata" => %{"content" => chunk}})}
    {:push, start ++ [delta], %{state | session: %{state.session | turn: true}}}
  end

  def handle_info({:agent_done, result}, %{session: %{topic: topic, join_ref: jr}} = state) do
    # Authoritative full text reconciles whatever the deltas accumulated.
    stop = push_frame(jr, topic, "llm_turn_stop", %{"metadata" => %{"content" => result, "status" => "ok"}})
    done = push_frame(jr, topic, "session_completed", %{})
    {:push, [{:text, stop}, {:text, done}], %{state | session: %{state.session | turn: false}}}
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
    state = track_topic(state, topic, join_ref)

    cond do
      topic == "desktop:control" ->
        Workbooks.DesktopControl.register(join_ref)
        state

      match?("session:" <> _, topic) ->
        bridge_session(topic, join_ref, state)

      true ->
        state
    end
  end

  defp maybe_track("phx_leave", topic, _join_ref, state) do
    Map.update(state, :topics, %{}, &Map.delete(&1, topic))
  end

  # Client→server cancel on a session channel (ws.cancelSession) — stop the run.
  defp maybe_track("cancel", "session:" <> id, _join_ref, state) do
    Workbooks.AgentSession.cancel(id)
    state
  end

  defp maybe_track(_event, _topic, _join_ref, state), do: state

  # Subscribe this socket to the AgentSession behind a joined session topic so
  # its run events fan out here. The desktop joins right after POSTing /api/run,
  # so the session exists; if not, we degrade to a quiet (unsubscribed) channel.
  defp bridge_session("session:" <> id = topic, join_ref, state) do
    case safe_subscribe(id) do
      :ok ->
        send(self(), {:bridge_session_started, topic, join_ref})
        Map.put(state, :session, %{topic: topic, join_ref: join_ref, turn: false})

      _ ->
        state
    end
  end

  defp safe_subscribe(id) do
    Workbooks.AgentSession.subscribe(id)
  rescue
    _ -> :error
  end

  defp track_topic(state, topic, join_ref) do
    Map.update(state, :topics, %{topic => join_ref}, &Map.put(&1, topic, join_ref))
  end

  defp push_frame(join_ref, topic, event, payload) do
    Jason.encode!([join_ref, nil, topic, event, payload])
  end
end

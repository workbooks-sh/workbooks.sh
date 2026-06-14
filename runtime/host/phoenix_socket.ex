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
      {:ok, [join_ref, ref, topic, event, payload]} ->
        {:push, {:text, ack(join_ref, ref, topic)}, maybe_track(event, topic, join_ref, payload, state)}

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
    tele(topic, "session_started", %{"agent" => %{"name" => "Waldo"}})
    {:push, {:text, push_frame(jr, topic, "session_started", %{"agent" => %{"name" => "Waldo"}})}, state}
  end

  def handle_info({:agent_step, ev}, %{session: %{topic: topic, join_ref: jr}} = state) do
    tcid = "s#{ev.step}"
    start_meta = %{"tool_name" => ev.tool, "tool_call_id" => tcid, "args" => ev.args}
    stop_meta = %{"tool_call_id" => tcid, "status" => if(ev.error, do: "error", else: "ok"), "result_size" => byte_size(ev.output || "")}
    tele(topic, "tool_call_start", %{"metadata" => start_meta})
    tele(topic, "tool_call_stop", %{"metadata" => stop_meta})

    {:push,
     [
       {:text, push_frame(jr, topic, "tool_call_start", %{"metadata" => start_meta})},
       {:text, push_frame(jr, topic, "tool_call_stop", %{"metadata" => stop_meta})}
     ], state}
  end

  def handle_info({:agent_delta, chunk}, %{session: %{topic: topic, join_ref: jr, turn: turn}} = state) do
    # The first delta of a text turn opens an assistant message; the rest append.
    if not turn, do: tele(topic, "llm_turn_start", %{"metadata" => %{}})
    tele(topic, "llm_delta", %{"metadata" => %{"content" => chunk}})
    start = if turn, do: [], else: [{:text, push_frame(jr, topic, "llm_turn_start", %{"metadata" => %{}})}]
    delta = {:text, push_frame(jr, topic, "llm_delta", %{"metadata" => %{"content" => chunk}})}
    {:push, start ++ [delta], %{state | session: %{state.session | turn: true}}}
  end

  def handle_info({:agent_done, result}, %{session: %{topic: topic, join_ref: jr}} = state) do
    # Authoritative full text reconciles whatever the deltas accumulated.
    tele(topic, "llm_turn_stop", %{"metadata" => %{"content" => result, "status" => "ok"}})
    tele(topic, "session_completed", %{})
    stop = push_frame(jr, topic, "llm_turn_stop", %{"metadata" => %{"content" => result, "status" => "ok"}})
    done = push_frame(jr, topic, "session_completed", %{})
    {:push, [{:text, stop}, {:text, done}], %{state | session: %{state.session | turn: false}}}
  end

  # Fan a translated session event out to the runtime:telemetry firehose.
  defp tele("session:" <> id, event, payload), do: Workbooks.TelemetryBus.emit(id, event, payload)
  defp tele(_topic, _event, _payload), do: :ok

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
  defp maybe_track("phx_join", topic, join_ref, _payload, state) do
    state = track_topic(state, topic, join_ref)

    cond do
      topic == "desktop:control" ->
        Workbooks.DesktopControl.register(join_ref, state[:tenant])
        state

      topic == "engine:env_prompt" ->
        # Tag the socket with its tenant (wb-g1yo) so prompts fan out only to the
        # requesting tenant's shell, not every connected desktop.
        Workbooks.EnvBroker.register_socket(join_ref, state[:tenant])
        state

      topic == "workgate:control" ->
        Workbooks.WorkgateBroker.register_socket(join_ref, state[:tenant])
        state

      topic == "runtime:telemetry" ->
        Workbooks.TelemetryBus.register(join_ref)
        state

      topic == "monorepo:watch" ->
        Workbooks.MonorepoWatcher.register(join_ref)
        state

      match?("session:" <> _, topic) ->
        bridge_session(topic, join_ref, state)

      true ->
        state
    end
  end

  defp maybe_track("phx_leave", topic, _join_ref, _payload, state) do
    Map.update(state, :topics, %{}, &Map.delete(&1, topic))
  end

  # Client→server cancel on a session channel (ws.cancelSession) — stop the run.
  # Gated by tenant (wb-g1yo.2): you can't cancel another tenant's run.
  defp maybe_track("cancel", "session:" <> id, _join_ref, _payload, state) do
    if session_tenant_ok?(id, state) do
      Workbooks.AgentSession.cancel(id)
    else
      Logger.warning("wb-g1yo.2: DENY cancel of session #{id} — tenant mismatch")
    end

    state
  end

  # Client→server workspace scope — tell the file watcher which folders to poll.
  defp maybe_track("set_scope", "workspace:control", _join_ref, payload, state) do
    if is_map(payload), do: Workbooks.MonorepoWatcher.set_scope(payload["folders"] || [])
    state
  end

  # Client→server env-prompt responses (the modal's Provide / Cancel) — deliver
  # to the agent blocked in EnvBroker.request/3.
  defp maybe_track("env:fulfill", "engine:env_prompt", _join_ref, payload, state) do
    if is_map(payload), do: Workbooks.EnvBroker.fulfill(payload["request_id"], payload["value"])
    state
  end

  defp maybe_track("env:cancel", "engine:env_prompt", _join_ref, payload, state) do
    if is_map(payload), do: Workbooks.EnvBroker.cancel(payload["request_id"])
    state
  end

  # Client→server OS-capability decision (the workgate Allow/Deny modal).
  defp maybe_track("permit", "workgate:control", _join_ref, payload, state) do
    if is_map(payload), do: Workbooks.WorkgateBroker.permit(payload["request_id"], payload["decision"])
    state
  end

  defp maybe_track(_event, _topic, _join_ref, _payload, state), do: state

  # Subscribe this socket to the AgentSession behind a joined session topic so
  # its run events fan out here. The desktop joins right after POSTing /api/run,
  # so the session exists; if not, we degrade to a quiet (unsubscribed) channel.
  defp bridge_session("session:" <> id = topic, join_ref, state) do
    if session_tenant_ok?(id, state) do
      case safe_subscribe(id) do
        :ok ->
          send(self(), {:bridge_session_started, topic, join_ref})
          Map.put(state, :session, %{topic: topic, join_ref: join_ref, turn: false})

        _ ->
          state
      end
    else
      # Cross-tenant join attempt: degrade to a quiet (unsubscribed) channel —
      # the joiner sees nothing of another tenant's run.
      Logger.warning("wb-g1yo.2: DENY join of session #{id} — tenant mismatch")
      state
    end
  end

  defp safe_subscribe(id) do
    Workbooks.AgentSession.subscribe(id)
  rescue
    _ -> :error
  end

  # wb-g1yo.2: a socket may only join/cancel a session owned by its tenant. Reject
  # ONLY on a definite cross-tenant mismatch (both tenants known AND different); a
  # nil on either side (dev/single-tenant socket, or a legacy/unknown run) is
  # grandfathered through so the desktop + dev flows are unaffected.
  defp session_tenant_ok?(id, state) do
    socket_tenant = state[:tenant]

    case Workbooks.AgentSession.status(id) do
      %{tenant: session_tenant} -> tenant_match?(session_tenant, socket_tenant)
      _ -> true
    end
  rescue
    _ -> true
  end

  @doc false
  # Pure tenant-match rule (wb-g1yo.2), public for testing — the one shared rule.
  def tenant_match?(session_tenant, socket_tenant),
    do: Workbooks.Tenant.visible?(session_tenant, socket_tenant)

  defp track_topic(state, topic, join_ref) do
    Map.update(state, :topics, %{topic => join_ref}, &Map.put(&1, topic, join_ref))
  end

  defp push_frame(join_ref, topic, event, payload) do
    Jason.encode!([join_ref, nil, topic, event, payload])
  end
end

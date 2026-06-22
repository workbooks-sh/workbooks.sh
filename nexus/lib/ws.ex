defmodule Nexus.Ws do
  @moduledoc """
  The bidirectional **WebSocket** transport for `Nexus.Live` sources — the duplex live channel the RCP
  handshake advertises (`transports.ws`). A client upgrades at `GET /ws` (authenticated; the socket
  carries the SERVER-DERIVED tenant/user, never the client's word), then exchanges JSON ops:

    * `{"op":"subscribe","source":"agent_run","params":{…}}` — run a registered `Nexus.Live` source; its
      emitted events stream back as JSON text frames (`{"type":"text"|"tools"|"final"|"done", …}`). The
      run executes in a linked process; killing the socket kills the run.
    * `{"op":"ping"}` → `{"type":"pong"}` — keepalive.

  WHY over SSE (`/live/:source`, one-way): the socket is BIDIRECTIONAL, so the same channel carries
  run output AND (next) mid-run steer/cancel + HITL. SSE stays for simple one-way consumers; this is
  the upgrade. Identity is injected here from the authenticated connection — a client can't spoof it.
  """
  @behaviour WebSock
  require Logger

  @impl true
  def init(state), do: {:ok, Map.put_new(state, :runner, nil)}

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"op" => "subscribe", "source" => source} = msg} when is_binary(source) ->
        # Inject the authenticated identity — the source (e.g. agent_run) scopes by tenant/user from
        # here, NOT from anything the client sent.
        params =
          (msg["params"] || %{})
          |> Map.merge(%{"tenant" => state.tenant, "u" => state.user || "anon", "role" => state[:role]})

        me = self()
        emit = fn ev -> send(me, {:ws_event, ev}) end
        runner = spawn_link(fn ->
          Nexus.Live.run(source, params, emit)
          send(me, {:ws_event, %{type: "done"}})
        end)

        {:ok, %{state | runner: runner}}

      {:ok, %{"op" => "ping"}} ->
        {:push, {:text, Jason.encode!(%{type: "pong"})}, state}

      _ ->
        {:push, {:text, Jason.encode!(%{type: "error", error: "bad message — expected {op, source}"})}, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({:ws_event, ev}, state), do: {:push, {:text, Jason.encode!(ev)}, state}
  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    r = state[:runner]
    if is_pid(r) and Process.alive?(r), do: Process.exit(r, :kill)
    :ok
  end
end

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

  @doc """
  Cross-Site WebSocket Hijacking guard for the `/ws` upgrade (red-team wb-k8wz). The browser does NOT
  preflight a WS handshake and CORS does not apply, so without this a logged-in user visiting evil.com
  could open a socket bound to their session. We require a browser-supplied `Origin` to be same-origin
  with the request host; a request with NO Origin (a non-browser client — the CLI/PAT, which carries no
  ambient cookie and so isn't CSWSH-able) is allowed.
  """
  @spec origin_ok?(String.t() | nil, String.t() | nil) :: boolean()
  def origin_ok?(origin, host)
  def origin_ok?(nil, _host), do: true
  def origin_ok?("", _host), do: true
  def origin_ok?(origin, host) when is_binary(origin) and is_binary(host), do: URI.parse(origin).host == host
  def origin_ok?(_, _), do: false

  # Edge proxies (Fly) idle-close a WebSocket after ~60s with no frames. A long agent turn (big reads +
  # an LLM call) can exceed that with no event to emit, so the proxy drops the socket → the client's
  # stream ends with no `done` AND `terminate/2` kills the runner mid-run (the run is LOST, no output).
  # A periodic server→client ping keeps the proxy's idle timer alive while the runner works; the client
  # pongs and keeps reading. Stops once the runner is gone.
  @heartbeat_ms 25_000

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

        # Kill any in-flight runner before starting a new one — a re-`subscribe` on the same socket
        # otherwise overwrites state.runner and orphans the prior linked process (it keeps running, no
        # longer tracked, so terminate/2 can't reap it): unbounded spawns per socket (red-team wb-e0dp).
        kill_runner(state[:runner])

        me = self()
        emit = fn ev -> send(me, {:ws_event, ev}) end
        runner = spawn_link(fn ->
          Nexus.Live.run(source, params, emit)
          send(me, {:ws_event, %{type: "done"}})
        end)

        Process.send_after(self(), :ws_heartbeat, @heartbeat_ms)
        {:ok, %{state | runner: runner}}

      {:ok, %{"op" => "shape", "name" => name} = msg} when is_binary(name) ->
        # Live-shapes subscription. Resolve the wire name against the allowlist (NEVER coerce the
        # client string to a module). Scope by the socket's SERVER-DERIVED tenant + the declared scope
        # field; send an initial snapshot, then deltas stream as {type:"shape:delta"} frames.
        case Nexus.Shapes.resolve(name) do
          {resource, scope_field} ->
            scope = msg["scope"]
            filter = shape_filter(scope_field, scope)
            rows = Nexus.Shapes.snapshot(resource, state.tenant, filter)
            :ok = Nexus.Shapes.subscribe(resource, state.tenant, filter)
            init = %{type: "shape:init", name: name, rows: Enum.map(rows, &encode_row/1)}
            {:push, {:text, Jason.encode!(init)}, Map.put(state, :shape_filters, Map.put(state[:shape_filters] || %{}, name, {resource, filter}))}

          :error ->
            {:push, {:text, Jason.encode!(%{type: "error", error: "unknown shape: #{name}"})}, state}
        end

      {:ok, %{"op" => "presence", "channel" => chan} = msg} when is_binary(chan) ->
        # Presence/typing for a channel, scoped to the socket's tenant + user. Subscribe once, then
        # touch — the resulting snapshot streams back as {type:"presence"} frames.
        user = state.user || "anon"
        :ok = Nexus.Presence.subscribe(state.tenant, chan)
        st = if msg["state"] == "typing", do: :typing, else: :online
        :ok = Nexus.Presence.touch(state.tenant, chan, user, st)
        {:ok, state}

      {:ok, %{"op" => "ping"}} ->
        {:push, {:text, Jason.encode!(%{type: "pong"})}, state}

      _ ->
        {:push, {:text, Jason.encode!(%{type: "error", error: "bad message — expected {op, source}"})}, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({:ws_event, ev}, state), do: {:push, {:text, Jason.encode!(ev)}, state}

  # A live-shape delta from Nexus.Shapes — re-tag with the shape name(s) this socket opened and push.
  def handle_info({:shape_delta, %{resource: resource, op: op, row: row}}, state) do
    name = shape_name_for(state[:shape_filters], resource)
    frame = %{type: "shape:delta", name: name, op: op, row: encode_row(row)}
    {:push, {:text, Jason.encode!(frame)}, state}
  end

  # A presence snapshot from Nexus.Presence.
  def handle_info({:presence, here}, state) do
    {:push, {:text, Jason.encode!(%{type: "presence", here: here})}, state}
  end

  # Heartbeat: while the run is still going, ping the client (keeps the edge proxy from idle-closing)
  # and re-arm. Once the runner has exited, stop pinging — the `done` frame has already gone out.
  def handle_info(:ws_heartbeat, state) do
    r = state[:runner]

    if is_pid(r) and Process.alive?(r) do
      Process.send_after(self(), :ws_heartbeat, @heartbeat_ms)
      {:push, {:ping, ""}, state}
    else
      {:ok, state}
    end
  end

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    kill_runner(state[:runner])
    :ok
  end

  # Unlink BEFORE killing: the runner is spawn_link'd (so a socket close reaps it), but when we kill the
  # PRIOR runner on re-subscribe we must not let the `:killed` exit propagate back through the link and
  # take down the socket itself. Unlink severs that, then the targeted kill stops just the old runner.
  defp kill_runner(r) when is_pid(r) do
    if Process.alive?(r) do
      Process.unlink(r)
      Process.exit(r, :kill)
    end

    :ok
  end

  defp kill_runner(_), do: :ok

  # Build the shape filter from the declared scope field + the requested scope value. No scope field
  # (whole-tenant shape) or no value → match every row in the tenant (tenant partition still applies).
  defp shape_filter(nil, _scope), do: fn _ -> true end
  defp shape_filter(_field, nil), do: fn _ -> true end
  defp shape_filter(field, scope) when is_atom(field), do: fn row -> Map.get(row, field) == scope end

  # Which opened shape name owns this resource (for re-tagging a delta on its way out).
  defp shape_name_for(nil, _resource), do: nil

  defp shape_name_for(filters, resource) do
    Enum.find_value(filters, fn {name, {res, _f}} -> if res == resource, do: name end)
  end

  # A resource row is a struct; send it as a plain map (drop the __struct__ key) for JSON.
  defp encode_row(%_{} = row), do: Map.from_struct(row)
  defp encode_row(row), do: row
end

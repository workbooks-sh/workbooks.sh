defmodule Workbooks.DesktopControl do
  @moduledoc """
  Runtime → desktop control bus (wb-d2nx.1) — the push side of the
  `desktop:control` Phoenix channel.

  The desktop already LISTENS on `desktop:control` and dispatches `tab_command`
  events (`%{action, path, session_id}`) to its tabs store; what was missing was
  anything on the runtime PUSHING those events. This is the keystone that lets
  Waldo (a normal agent calling the `wb` tool) actually drive the app: open and
  focus tabs, prompt for a key, retheme — by emitting a control event the
  connected shell acts on.

  No Phoenix.PubSub in this runtime, so the fan-out is a plain duplicate-key
  `Registry`: every connected `Workbooks.PhoenixSocket` that joins
  `desktop:control` registers itself (value = its channel join_ref), and a push
  dispatches an Erlang message to each — the socket forwards it as a v2 channel
  frame. Same node as the agent's `wb` call, so no distribution needed.
  """
  @registry Workbooks.DesktopControl.Registry
  @topic "desktop:control"
  @key :sockets

  @doc "Child spec — a duplicate-key Registry holding the connected control sockets."
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @doc """
  Register the calling socket process as a control listener, keyed by its
  channel join_ref so future pushes address the right channel instance. Called
  by PhoenixSocket when the desktop joins `desktop:control`.
  """
  def register(join_ref, tenant \\ nil) do
    # Idempotent per join_ref: drop any prior entry for this pid so a rejoin
    # doesn't leave a stale join_ref that pushes to a dead channel. The tenant is
    # stored so app-control pushes (theme/tab/…) reach only that tenant's shell
    # (wb-g1yo) — not every connected desktop on a shared nexus.
    Registry.unregister(@registry, @key)
    Registry.register(@registry, @key, {tenant, join_ref})
  end

  # Same grandfather rule as the rest of wb-g1yo: nil on either side passes.
  defp tenant_visible?(socket_tenant, req_tenant),
    do: is_nil(socket_tenant) or is_nil(req_tenant) or socket_tenant == req_tenant

  @doc "How many desktop shells are currently listening (diagnostics / no-op guard)."
  def listeners do
    Registry.lookup(@registry, @key) |> length()
  rescue
    _ -> 0
  end

  @doc """
  Push a `desktop:control` channel event to every connected shell. `event` is
  the Phoenix event name (e.g. `"tab_command"`), `payload` a JSON-able map.
  Returns `{:ok, n}` with the number of shells reached.
  """
  def push(event, payload, tenant \\ nil) when is_binary(event) and is_map(payload) do
    entries = Registry.lookup(@registry, @key)
    n = Enum.count(entries, fn {_pid, {st, _jr}} -> tenant_visible?(st, tenant) end)

    for {pid, {st, join_ref}} <- entries, tenant_visible?(st, tenant) do
      send(pid, {:channel_push, join_ref, @topic, event, payload})
    end

    {:ok, n}
  rescue
    # The registry may not be up (e.g. WB_WEB without the socket) — never raise
    # into an agent's tool call; report zero reach instead.
    _ -> {:ok, 0}
  end

  # ── Convenience emitters (the verbs Waldo's toolkit speaks) ────────────────

  @doc "Open/close/focus a tab by path in `tenant`'s connected shell."
  def tab(action, path, session_id \\ nil, tenant \\ nil) when action in ["open", "close", "focus"] do
    push("tab_command", %{"action" => action, "path" => path, "session_id" => session_id}, tenant)
  end

  @doc """
  Drive a non-tab app capability — theme switch, bookmark add, workspace create.
  The shell's app_command handler dispatches on `action`. Generic so new
  capabilities are one CLI verb + one desktop case, no new channel event.
  Scoped to `tenant`'s shell (wb-g1yo).
  """
  def command(action, args, tenant \\ nil) when is_binary(action) and is_map(args) do
    push("app_command", Map.put(args, "action", action), tenant)
  end
end

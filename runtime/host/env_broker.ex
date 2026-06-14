defmodule Workbooks.EnvBroker do
  @moduledoc """
  Agent-triggered API-key / env-var prompts (wb-kbq5.2 / wb-d2nx.4). When an
  agent needs a value it doesn't have, it asks the connected desktop to prompt
  the user — a request/response over the `engine:env_prompt` channel:

      agent ─request(name,reason)→ push env_prompt to the shell
      user types value in the modal ─env:fulfill→ fulfill(request_id, value)
      agent unblocks with the value

  No GenServer: two Registries carry it — `Sockets` (duplicate-key) holds the
  connected shells for fan-out (mirrors DesktopControl), `Pending` (unique-key)
  maps a request_id to the WAITING caller pid so a fulfill can wake it.
  """
  @sockets Workbooks.EnvBroker.Sockets
  @pending Workbooks.EnvBroker.Pending
  @topic "engine:env_prompt"

  @doc "Child specs — both registries (add to the supervision tree)."
  def children do
    [
      Registry.child_spec(keys: :duplicate, name: @sockets),
      Registry.child_spec(keys: :unique, name: @pending)
    ]
  end

  @doc "A connected shell joined engine:env_prompt — remember it for fan-out."
  def register_socket(join_ref) do
    Registry.unregister(@sockets, :shells)
    Registry.register(@sockets, :shells, join_ref)
  end

  @doc "Is any desktop shell able to surface a prompt right now?"
  def desktop_subscribed? do
    Registry.lookup(@sockets, :shells) != []
  rescue
    _ -> false
  end

  @doc """
  Ask the user for `name` (with optional `reason`) and BLOCK until they answer
  or `timeout`. Returns {:ok, value} | {:error, :no_desktop | :timeout}.
  """
  def request(name, reason \\ nil, timeout \\ 120_000) do
    if desktop_subscribed?() do
      request_id = "env-#{System.unique_integer([:positive])}"
      Registry.register(@pending, request_id, nil)
      push_prompt(request_id, name, reason)

      receive do
        {:env_fulfilled, ^request_id, value} ->
          Registry.unregister(@pending, request_id)
          {:ok, value}

        {:env_cancelled, ^request_id} ->
          Registry.unregister(@pending, request_id)
          {:error, :cancelled}
      after
        timeout ->
          Registry.unregister(@pending, request_id)
          {:error, :timeout}
      end
    else
      {:error, :no_desktop}
    end
  end

  @doc "Deliver a fulfilled value to the waiting requester."
  def fulfill(request_id, value), do: deliver(request_id, {:env_fulfilled, request_id, value})

  @doc "Tell the waiting requester the user cancelled."
  def cancel(request_id), do: deliver(request_id, {:env_cancelled, request_id})

  defp deliver(request_id, msg) do
    case Registry.lookup(@pending, request_id) do
      [{pid, _} | _] -> send(pid, msg); :ok
      _ -> :error
    end
  end

  defp push_prompt(request_id, name, reason) do
    payload = %{"request_id" => request_id, "name" => name, "reason" => reason}

    Registry.dispatch(@sockets, :shells, fn entries ->
      for {pid, join_ref} <- entries do
        send(pid, {:channel_push, join_ref, @topic, "env_prompt", payload})
      end
    end)
  end
end

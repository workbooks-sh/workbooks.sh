defmodule Workbooks.WorkgateBroker do
  @moduledoc """
  Agent-triggered OS-capability approvals (wb-kbq5.3) over the `workgate:control`
  channel. Same request/response shape as `Workbooks.EnvBroker` (env keys) but
  for capability grants: the agent asks, the connected desktop shows an
  Allow/Deny modal, the user's `permit` decision unblocks the agent.

      agent ─request(capability,reason)→ push workgate_request
      user clicks Allow/Deny ─permit→ permit(request_id, decision)
      agent unblocks with :allow | :deny

  (The env + workgate brokers share a pattern; a generic PromptBroker could merge
  them later — kept separate now so the proven env flow isn't destabilized.)
  """
  @sockets Workbooks.WorkgateBroker.Sockets
  @pending Workbooks.WorkgateBroker.Pending
  @topic "workgate:control"

  def children do
    [
      Registry.child_spec(keys: :duplicate, name: @sockets),
      Registry.child_spec(keys: :unique, name: @pending)
    ]
  end

  def register_socket(join_ref) do
    Registry.unregister(@sockets, :shells)
    Registry.register(@sockets, :shells, join_ref)
  end

  def desktop_subscribed? do
    Registry.lookup(@sockets, :shells) != []
  rescue
    _ -> false
  end

  @doc "Ask the user to Allow/Deny `capability`. Blocks. Returns :allow | :deny | {:error, reason}."
  def request(capability, reason \\ nil, timeout \\ 120_000) do
    if desktop_subscribed?() do
      request_id = "wg-#{System.unique_integer([:positive])}"
      Registry.register(@pending, request_id, nil)

      push_request(request_id, capability, reason)

      receive do
        {:workgate_permit, ^request_id, decision} ->
          Registry.unregister(@pending, request_id)
          decision
      after
        timeout ->
          Registry.unregister(@pending, request_id)
          {:error, :timeout}
      end
    else
      {:error, :no_desktop}
    end
  end

  @doc "Deliver the user's permit decision (\"allow\" | \"deny\") to the waiting agent."
  def permit(request_id, decision) do
    d = if decision in ["allow", :allow], do: :allow, else: :deny

    case Registry.lookup(@pending, request_id) do
      [{pid, _} | _] -> send(pid, {:workgate_permit, request_id, d}); :ok
      _ -> :error
    end
  end

  defp push_request(request_id, capability, reason) do
    payload = %{
      "request_id" => request_id,
      "capability" => capability,
      "reason" => reason,
      "policy_decision" => "prompt_user"
    }

    Registry.dispatch(@sockets, :shells, fn entries ->
      for {pid, join_ref} <- entries do
        send(pid, {:channel_push, join_ref, @topic, "workgate_request", payload})
      end
    end)
  end
end

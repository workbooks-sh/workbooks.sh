defmodule Nexus.Authz.DualControl do
  @moduledoc """
  **Dual-control** for root-scope and destructive actions (wb-d8ac.9).

  Some actions are too dangerous for a single actor — least of all a single *agent* acting on a
  prompt-injected message (the "Org-Admin agent offboards a person from one chat message" scenario).
  Dual-control requires a SECOND, DISTINCT, authorized approver before such an action executes: a
  request is recorded as pending; only a different admin+ can approve it; the action runs only once
  approved. The approver can never be the requester (no rubber-stamping yourself).

  Built on the org-isolated control-plane store (kind `:dual`). A request is durable so approval can
  happen out-of-band (a human approving an agent's request minutes later).
  """
  alias Nexus.ControlPlane, as: CP

  # Actions that MUST go through dual-control. Matched by prefix so a family (`member.*`) is covered.
  @guarded ~w(member.offboard member.remove access.revoke grant.owner workspace.delete nexus.destroy secrets.rotate)

  @doc "Does `action` require dual-control? (root-scope / destructive families)."
  @spec required?(String.t()) :: boolean
  def required?(action) when is_binary(action),
    do: Enum.any?(@guarded, &(action == &1 or String.starts_with?(action, &1 <> ".")))

  @doc """
  Record a pending dangerous `action` requested by `requester` (`%{user:, role:}`), with an optional
  `payload` (the action's args) and `id`. Returns `{:ok, id}`. The requester must already be allowed
  to *propose* it (member+); approval is the second gate.
  """
  @spec request(String.t(), String.t(), map, keyword) :: {:ok, String.t()} | {:error, atom}
  def request(org, action, requester, opts \\ []) when is_binary(action) do
    if Nexus.Authz.may?(requester[:role] || "viewer", :write) do
      id = Keyword.get(opts, :id, gen_id())

      {:ok, _} =
        CP.put(org, :dual, id, %{
          action: action,
          payload: Keyword.get(opts, :payload, %{}),
          requested_by: requester[:user],
          status: "pending",
          approved_by: nil,
          created_at: System.os_time(:millisecond)
        })

      {:ok, id}
    else
      {:error, :not_allowed_to_request}
    end
  end

  @doc """
  Approve a pending request as `approver` (`%{user:, role:}`). Fails if the request is unknown, not
  pending, the approver is the requester (self-approval), or the approver is not admin+. On success
  marks it approved and returns `{:ok, record}` — the caller then executes the action.
  """
  @spec approve(String.t(), String.t(), map) :: {:ok, map} | {:error, atom}
  def approve(org, id, approver) do
    with {:ok, rec} <- get(org, id),
         :pending <- status_atom(rec),
         :ok <- check_distinct(rec, approver),
         :ok <- check_admin(approver) do
      CP.update(org, :dual, id, %{status: "approved", approved_by: approver[:user], approved_at: System.os_time(:millisecond)})
    else
      {:error, _} = e -> e
      other when is_atom(other) -> {:error, :not_pending}
    end
  end

  @doc "Fetch one request. `{:ok, rec} | {:error, :not_found}`."
  def get(org, id), do: CP.get(org, :dual, id)

  @doc "Is the request approved and ready to execute?"
  @spec approved?(String.t(), String.t()) :: boolean
  def approved?(org, id) do
    match?({:ok, %{status: "approved"}}, get(org, id))
  end

  @doc "All still-pending requests in the org."
  def pending(org), do: CP.list(org, :dual) |> Enum.filter(&(&1[:status] == "pending"))

  defp status_atom(%{status: "pending"}), do: :pending
  defp status_atom(_), do: :not_pending

  defp check_distinct(%{requested_by: r}, %{user: a}) when is_binary(r) and r == a, do: {:error, :self_approval}
  defp check_distinct(_, _), do: :ok

  defp check_admin(approver) do
    if Nexus.Authz.may?(approver[:role] || "viewer", :manage), do: :ok, else: {:error, :approver_not_admin}
  end

  defp gen_id, do: "dc_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
end

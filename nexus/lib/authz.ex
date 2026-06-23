defmodule Nexus.Authz do
  @moduledoc """
  Authorization — the WHAT half of access control (epic wb-kodp, wb-h88g).

  `Nexus.Auth` answers WHO a request is (server-derived identity). `Nexus.Authz` answers what that
  identity MAY do. Two tiny, pure, fail-closed predicates the whole app gates through — kept deliberately
  small so the policy is auditable at a glance:

    * `may?/2` — does a role meet an action's minimum? (route role-gating)
    * `may_access?/4` — may an identity act on a target given its visibility + owner? (per-workspace ACL)

  Reuses `Nexus.Auth`'s role rank (viewer < member < admin < owner); unknown action / blank role / nil
  identity all fail closed.
  """

  # The ONE action→minimum-role table. An action not listed here is denied outright (fail closed).
  @action_min %{read: "viewer", write: "member", manage: "admin", own: "owner"}

  @doc "May a principal with `role` perform `action`? Unknown action / blank role ⇒ false (fail closed)."
  @spec may?(String.t() | nil, atom()) :: boolean()
  def may?(role, action) do
    case Map.get(@action_min, action) do
      nil -> false
      min -> is_binary(role) and role != "" and Nexus.Auth.role_at_least?(role, min)
    end
  end

  @doc """
  May `identity` (`%{role:, user:}`) take `action` on a target of the given `visibility`, owned by
  `owner_uid`?

    * `"public"` — read by anyone; write/manage gated by role (`may?/2`).
    * `"draft"`  — work-in-progress: only the owner, or an admin+ (`may?(:manage)`).
    * anything else (`"private"`/default) — an org member+ for any action (`may?(:write)`).
  """
  @spec may_access?(map(), String.t(), String.t() | nil, atom()) :: boolean()
  def may_access?(identity, visibility, owner_uid, action) do
    role = identity[:role] || "viewer"

    case visibility do
      "public" -> action == :read or may?(role, action)
      "draft" -> owner?(identity[:user], owner_uid) or may?(role, :manage)
      _private -> may?(role, :write)
    end
  end

  defp owner?(uid, owner_uid), do: is_binary(uid) and uid != "" and uid == owner_uid
end

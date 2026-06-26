defmodule Nexus.Authz.Grants do
  @moduledoc """
  The **persisted role + grant model** with separation of duties (wb-d8ac.6).

  `Nexus.Authz` is the pure policy ladder (viewer < member < admin < owner) and the per-target ACL
  predicates. What it lacked was *state*: a real, durable record of **who holds which role in which
  workspace**, and **who was granted which capability, by whom, until when** — the thing our entire
  capability-gated-execution story rests on. `private: true` is not an authorization system; this is.

  Built on `Nexus.ControlPlane` (org-scoped, structurally isolated by `{org, kind, id}`), so every
  role/grant is partitioned by org and can never be read or mutated across orgs. Two kinds:

    * `:wsrole` — `"<workspace>:<user>" → %{workspace, user, role, granted_by, created_at}`. A
      WORKSPACE-SCOPED role override: a user can be `admin` in one workspace and `viewer` in another,
      instead of one global org role. `role_in/3` resolves the workspace role, falling back to the
      user's org role when there is no override.
    * `:grant`  — `"<scope>:<principal>:<capability>" → %{..., granted_by, expires_at}`. A capability
      granted to a principal (a user OR an agent) in a scope, by a grantor, optionally time-boxed.

  ## Separation of duties (the part that makes it real)

  Authorization changes are themselves authorized, and a single actor cannot unilaterally escalate:

    * Only an `admin`+ may assign roles or issue grants (`may?(:manage)`).
    * **No self-escalation** — you cannot grant yourself a role higher than you already hold.
    * **No grant-above-self** — you cannot assign a role higher than your own (an admin can't mint an
      owner). Promotion to `owner` requires an existing `owner`.

  These return `{:error, reason}` rather than silently allowing — the caller (a route handler) turns
  that into a 403. Dual-control on the *most* dangerous actions layers on top (wb-d8ac.9).
  """
  alias Nexus.ControlPlane, as: CP

  @roles ~w(viewer member owner admin)
  @rank %{"viewer" => 0, "member" => 1, "admin" => 2, "owner" => 3}

  # ── workspace-scoped roles ───────────────────────────────────────────────────────────────────────

  @doc """
  Assign `user` the `role` in `workspace`, performed by `actor` (`%{user:, role:}`). Enforces
  separation of duties. Returns `{:ok, record} | {:error, reason}`.
  """
  @spec assign_role(String.t(), String.t(), String.t(), String.t(), map) ::
          {:ok, map} | {:error, atom}
  def assign_role(org, workspace, user, role, actor)
      when is_binary(org) and is_binary(workspace) and is_binary(user) and role in @roles do
    with :ok <- check_can_administer(actor),
         :ok <- check_not_self_escalation(actor, user, role),
         :ok <- check_not_above_self(actor, role) do
      CP.put(org, :wsrole, "#{workspace}:#{user}", %{
        workspace: workspace,
        user: user,
        role: role,
        granted_by: actor[:user],
        created_at: System.os_time(:millisecond)
      })
    end
  end

  @doc "The workspace-scoped role for `user`, or `nil` if there is no override in `workspace`."
  @spec workspace_role(String.t(), String.t(), String.t()) :: String.t() | nil
  def workspace_role(org, workspace, user) do
    case CP.get(org, :wsrole, "#{workspace}:#{user}") do
      {:ok, %{role: role}} -> role
      _ -> nil
    end
  end

  @doc """
  The EFFECTIVE role for `user` in `workspace`: the workspace override if present, else the user's
  org-level role (`org_role` fallback, default `"viewer"`). This is what gating should consult.
  """
  @spec role_in(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def role_in(org, workspace, user, org_role \\ "viewer") do
    workspace_role(org, workspace, user) || org_role || "viewer"
  end

  @doc "May `user` take `action` in `workspace`, given their org-level role? (workspace role wins.)"
  @spec may_in?(String.t(), String.t(), String.t(), atom, String.t()) :: boolean
  def may_in?(org, workspace, user, action, org_role \\ "viewer") do
    Nexus.Authz.may?(role_in(org, workspace, user, org_role), action)
  end

  @doc "List all role overrides in a workspace — `[%{user:, role:, granted_by:}]`."
  @spec roster(String.t(), String.t()) :: [map]
  def roster(org, workspace) do
    CP.list(org, :wsrole) |> Enum.filter(&(&1[:workspace] == workspace))
  end

  # ── capability grants ────────────────────────────────────────────────────────────────────────────

  @doc """
  Grant `capability` to `principal` (a user id or agent name) within `scope`, by `actor`. Optional
  `expires_at` (unix ms) time-boxes it. Only an admin+ may grant. `{:ok, record} | {:error, reason}`.
  """
  @spec grant(String.t(), String.t(), String.t(), String.t(), map, keyword) ::
          {:ok, map} | {:error, atom}
  def grant(org, scope, principal, capability, actor, opts \\ [])
      when is_binary(scope) and is_binary(principal) and is_binary(capability) do
    with :ok <- check_can_administer(actor) do
      CP.put(org, :grant, "#{scope}:#{principal}:#{capability}", %{
        scope: scope,
        principal: principal,
        capability: capability,
        granted_by: actor[:user],
        created_at: System.os_time(:millisecond),
        expires_at: Keyword.get(opts, :expires_at)
      })
    end
  end

  @doc "Revoke a grant. Anyone admin+ may revoke (revocation is fail-safe, so it isn't SoD-gated up)."
  @spec revoke(String.t(), String.t(), String.t(), String.t()) :: :ok
  def revoke(org, scope, principal, capability) do
    CP.delete(org, :grant, "#{scope}:#{principal}:#{capability}")
  end

  @doc """
  Does `principal` currently hold `capability` in `scope`? Honors expiry: an expired grant returns
  false (and is treated as gone). `now` overridable for testing.
  """
  @spec granted?(String.t(), String.t(), String.t(), String.t(), integer | nil) :: boolean
  def granted?(org, scope, principal, capability, now \\ nil) do
    now = now || System.os_time(:millisecond)

    case CP.get(org, :grant, "#{scope}:#{principal}:#{capability}") do
      {:ok, %{expires_at: exp}} when is_integer(exp) -> exp > now
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc "All live (non-expired) grants held by `principal` across scopes — the principal's privilege set."
  @spec grants_for(String.t(), String.t(), integer | nil) :: [map]
  def grants_for(org, principal, now \\ nil) do
    now = now || System.os_time(:millisecond)

    CP.list(org, :grant)
    |> Enum.filter(&(&1[:principal] == principal))
    |> Enum.reject(fn g -> is_integer(g[:expires_at]) and g[:expires_at] <= now end)
  end

  # ── separation-of-duties checks ──────────────────────────────────────────────────────────────────

  defp check_can_administer(actor) do
    if Nexus.Authz.may?(actor[:role] || "viewer", :manage), do: :ok, else: {:error, :not_an_admin}
  end

  # An actor cannot assign a role strictly above their own (admin can't mint an owner).
  defp check_not_above_self(actor, role) do
    if rank(role) <= rank(actor[:role]), do: :ok, else: {:error, :grant_above_self}
  end

  # An actor cannot escalate THEMSELF to a higher role (needs a second authority — true SoD).
  defp check_not_self_escalation(actor, user, role) do
    same? = is_binary(actor[:user]) and actor[:user] == user
    if same? and rank(role) > rank(actor[:role]), do: {:error, :self_escalation}, else: :ok
  end

  defp rank(role), do: Map.get(@rank, role, -1)
end

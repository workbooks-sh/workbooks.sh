defmodule Nexus.ControlPlane do
  @moduledoc """
  The hosted control-plane role — the backend behind the cloud dashboard's `/api/platform/*` API
  (nexus fleet, workspaces, usage, storage). A nexus runs in this role only when **enabled** (the
  `WB_CONTROL_PLANE` deploy flag); a tenant runtime never does.

  **Security model (the whole point of this module):** every record is owned by an `org` — the
  WorkOS-issued JWT's `org_id`, surfaced as `conn.assigns[:tenant]` by `Nexus.Auth.Jwt`. Every read
  and write is org-scoped at the DATA layer (`list/get/update/delete` all take `org` and filter on
  it), so a caller can only ever see or touch its OWN records. Ownership IDOR is closed here, not
  re-checked per route. The registry below is the in-memory tier (ETS, tenant-partitioned) that the
  Fly/Neon-backed provisioner layers onto — but the isolation contract is identical and is what the
  adversarial tests pin.
  """

  @doc "Is this nexus running in the control-plane role? (the WB_CONTROL_PLANE deploy flag)."
  def enabled?, do: System.get_env("WB_CONTROL_PLANE") in ~w(1 true)

  @doc """
  Wire the auth adapter for the control-plane role (called at boot). When enabled, the control-plane
  MUST authenticate every caller via the WorkOS-issued JWT (`org_id` → tenant), so we force
  `Nexus.Auth.Jwt` and configure it from the deploy env (the OIDC provider this role trusts — public
  config, not a secret):

      WB_OIDC_JWKS_URL     the IdP JWKS endpoint (https; required — without it auth fails CLOSED)
      WB_OIDC_TENANT_CLAIM the claim carrying the org/tenant (default "org_id")
      WB_OIDC_ISS          expected issuer (optional but recommended)

  Fail-closed: a missing JWKS URL leaves `jwks_url: nil`, so every token 401s — the control-plane is
  inert, never wide-open. Returns `:ok | :skip`.
  """
  def configure_auth do
    if enabled?() do
      cfg =
        [
          jwks_url: System.get_env("WB_OIDC_JWKS_URL"),
          tenant_claim: System.get_env("WB_OIDC_TENANT_CLAIM") || "org_id"
        ] ++ if((iss = System.get_env("WB_OIDC_ISS")), do: [iss: iss], else: [])

      Application.put_env(:nexus, Nexus.Auth.Jwt, cfg)
      Application.put_env(:nexus, :auth, Nexus.Auth.Jwt)
      :ok
    else
      :skip
    end
  end

  # ── registry (tenant-partitioned, durable DETS) ────────────────────────────────────────────────
  # Key is always {org, kind, id} so a lookup is physically impossible to satisfy with another org's
  # row — isolation is structural, not a WHERE clause we might forget. The table is owned by
  # Nexus.ControlPlane.Store (a long-lived GenServer); rows persist across restarts.
  defp table, do: Nexus.ControlPlane.Store.table()

  @doc "List an org's records of a kind (`:nexus` | `:workspace`). Only ever this org's rows."
  def list(org, kind) when is_binary(org) do
    table()
    |> :dets.match_object({{org, kind, :_}, :_})
    |> Enum.map(fn {_k, rec} -> rec end)
    |> Enum.sort_by(& &1[:created_at])
  end

  @doc "Get one record by id, scoped to `org`. `{:ok, rec} | {:error, :not_found}`."
  def get(org, kind, id) when is_binary(org) do
    case :dets.lookup(table(), {org, kind, id}) do
      [{_k, rec}] -> {:ok, rec}
      [] -> {:error, :not_found}
    end
  end

  @doc "Create a record under `org`. `attrs` is a map; `:id`/`:org`/`:created_at` are stamped here."
  def put(org, kind, id, attrs) when is_binary(org) and is_binary(id) do
    rec = Map.merge(attrs, %{id: id, org: org, kind: kind})
    rec = Map.put_new(rec, :created_at, System.os_time(:millisecond))
    :dets.insert(table(), {{org, kind, id}, rec})
    {:ok, rec}
  end

  @doc "Patch a record's `attrs` (only the given keys), scoped to `org`. Never crosses orgs."
  def update(org, kind, id, attrs) when is_binary(org) do
    case get(org, kind, id) do
      {:ok, rec} ->
        merged = Map.merge(rec, attrs)
        :dets.insert(table(), {{org, kind, id}, merged})
        {:ok, merged}

      err ->
        err
    end
  end

  @doc "Delete a record scoped to `org`. A foreign org's delete is a silent no-op (returns :ok)."
  def delete(org, kind, id) when is_binary(org) do
    :dets.delete(table(), {org, kind, id})
    :ok
  end

  @doc false
  # Test helper — wipe the whole registry for a clean slate.
  def reset, do: :dets.delete_all_objects(table())
end

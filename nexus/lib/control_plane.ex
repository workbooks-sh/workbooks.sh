defmodule Nexus.ControlPlane do
  @moduledoc """
  The hosted control-plane role — the backend behind the cloud dashboard's `/api/platform/*` API
  (nexus fleet, workspaces, usage, storage). A nexus runs in this role only when **enabled** (the
  `WB_CONTROL_PLANE` deploy flag); a tenant runtime never does.

  **Security model (the whole point of this module):** every record is owned by an `org` — the caller's
  org from their native session / PAT, surfaced as `conn.assigns[:tenant]` by `Nexus.Auth.Cloud`. Every read
  and write is org-scoped at the DATA layer (`list/get/update/delete` all take `org` and filter on
  it), so a caller can only ever see or touch its OWN records. Ownership IDOR is closed here, not
  re-checked per route. The registry below is the in-memory tier (ETS, tenant-partitioned) that the
  Fly/Neon-backed provisioner layers onto — but the isolation contract is identical and is what the
  adversarial tests pin.
  """

  @doc "Is this nexus running in the control-plane role? (the WB_CONTROL_PLANE deploy flag)."
  def enabled?, do: System.get_env("WB_CONTROL_PLANE") in ~w(1 true)

  @doc """
  Wire the auth adapter for the control-plane role (called at boot). The control-plane authenticates
  via OUR OWN identity — a native session cookie (`Nexus.Auth.Session`, set by `/auth/login`) for the
  dashboard, or a `wbk_` personal-access token for the `work` CLI — both resolved by `Nexus.Auth.Cloud`,
  both mapping to the caller's `org` tenant. No third-party IdP. Returns `:ok | :skip`.
  """
  def configure_auth do
    if enabled?() do
      Application.put_env(:nexus, :auth, Nexus.Auth.Cloud)

      # Wire the OIDC/JWT validation config from the deploy env so the Cloud adapter can verify a WorkOS
      # SSO JWT (it also accepts a `wbk_` CLI PAT, validated separately). Set even when the vars are
      # unset: NO jwks_url ⇒ fail-closed (Nexus.Auth.Jwt 401s every JWT), the correct posture for a
      # control plane that must never accept an unverifiable token.
      Application.put_env(:nexus, Nexus.Auth.Jwt,
        jwks_url: System.get_env("WB_OIDC_JWKS_URL"),
        tenant_claim: System.get_env("WB_OIDC_TENANT_CLAIM"),
        issuer: System.get_env("WB_OIDC_ISS")
      )

      :ok
    else
      :skip
    end
  end

  # ── registry (tenant-partitioned, durable DETS) ────────────────────────────────────────────────
  # Key is always {org, kind, id} so a lookup is physically impossible to satisfy with another org's
  # row — isolation is structural, not a WHERE clause we might forget. The table is owned by
  # Nexus.ControlPlane.Store (SQLite, in the litestream-replicated nexus.db); rows survive restarts.
  alias Nexus.ControlPlane.Store

  @doc "List an org's records of a kind (`:nexus` | `:workspace`). Only ever this org's rows."
  def list(org, kind) when is_binary(org) do
    Store.list(org, kind) |> Enum.sort_by(& &1[:created_at])
  end

  @doc "Get one record by id, scoped to `org`. `{:ok, rec} | {:error, :not_found}`."
  def get(org, kind, id) when is_binary(org) do
    case Store.get(org, kind, id) do
      {:ok, rec} -> {:ok, rec}
      :error -> {:error, :not_found}
    end
  end

  @doc "Create a record under `org`. `attrs` is a map; `:id`/`:org`/`:created_at` are stamped here."
  def put(org, kind, id, attrs) when is_binary(org) and is_binary(id) do
    rec = Map.merge(attrs, %{id: id, org: org, kind: kind})
    rec = Map.put_new(rec, :created_at, System.os_time(:millisecond))
    :ok = Store.put(org, kind, id, rec)
    {:ok, rec}
  end

  @doc "Patch a record's `attrs` (only the given keys), scoped to `org`. Never crosses orgs."
  def update(org, kind, id, attrs) when is_binary(org) do
    case get(org, kind, id) do
      {:ok, rec} ->
        merged = Map.merge(rec, attrs)
        :ok = Store.put(org, kind, id, merged)
        {:ok, merged}

      err ->
        err
    end
  end

  @doc "Delete a record scoped to `org`. A foreign org's delete is a silent no-op (returns :ok)."
  def delete(org, kind, id) when is_binary(org), do: Store.delete(org, kind, id)

  @doc false
  # Test helper — wipe the whole registry for a clean slate.
  def reset, do: Store.delete_all()
end

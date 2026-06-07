defmodule Workbooks.Auth do
  @moduledoc """
  Authenticate a request and scope it to a tenant. Production validates
  BetterAuth-issued JWTs via `Workbooks.Auth.Guardian` (AUTH.org) and extracts
  `organizationId` as the tenant. With no `Authorization: Bearer` header it
  falls back to the `x-tenant` dev header so demos/serving boot without a gateway.

  Assigns: `:identity` (%{user_id, tenant_id, session_id}) and `:tenant`.
  """
  import Plug.Conn
  @behaviour Plug

  alias Workbooks.Auth.Guardian

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case bearer(conn) do
      nil -> no_bearer(conn)
      token -> verify(conn, token)
    end
  end

  # No credential. Single-tenant allows the dev fallback; multi-tenant does NOT —
  # isolation can't rest on a spoofable header, so a request must be authenticated.
  # `/health` is infra liveness (no tenant data) — always allowed so load-balancer
  # and `wb deploy verify` checks work in either mode.
  defp no_bearer(conn) do
    cond do
      conn.request_path == "/health" -> dev_fallback(conn)
      Workbooks.Tenancy.multi?() -> conn |> send_resp(401, "authentication required (multi-tenant)") |> halt()
      true -> dev_fallback(conn)
    end
  end

  # Desktop daemon: the per-boot token from the discovery file authenticates the
  # local WebView. Only honored when WB_DESKTOP=1 (the token doesn't exist
  # otherwise) and it scopes to the single local tenant; anything else → JWT.
  defp verify(conn, token) do
    if Workbooks.Desktop.enabled?() and Plug.Crypto.secure_compare(token, Workbooks.Desktop.token()) do
      tenant = Workbooks.Desktop.tenant()
      conn |> assign(:identity, %{user_id: tenant, tenant_id: tenant, session_id: nil}) |> assign(:tenant, tenant)
    else
      verify_jwt(conn, token)
    end
  end

  defp verify_jwt(conn, token) do
    case Guardian.resource_from_token(token) do
      {:ok, identity, _claims} ->
        conn |> assign(:identity, identity) |> assign(:tenant, identity.tenant_id)

      {:error, _reason} ->
        conn |> send_resp(401, "unauthorized") |> halt()
    end
  end

  defp dev_fallback(conn) do
    tenant = conn |> get_req_header("x-tenant") |> List.first() || "dev"

    conn
    |> assign(:identity, %{user_id: tenant, tenant_id: tenant, session_id: nil})
    |> assign(:tenant, tenant)
  end

  defp bearer(conn) do
    case conn |> get_req_header("authorization") |> List.first() do
      "Bearer " <> token -> token
      _ -> nil
    end
  end
end

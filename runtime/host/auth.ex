defmodule Workbooks.Auth do
  @moduledoc """
  Authenticate a request and scope it to a tenant.

  Auth ladder (first match wins):
    1. Public allowlist (/health, /.well-known/*) — always open.
    2. WB_DESKTOP=1 + desktop per-boot token — local WebView.
    3. WB_PUBLIC_BEARER set — shared-secret path for locked cloud deploys.
       `Authorization: Bearer <WB_PUBLIC_BEARER>` → tenant from `WB_TENANT`
       (default "local"). Any other/absent bearer → 401, NO dev fallback.
    4. BetterAuth/Guardian JWT — production multi-tenant path.
    5. x-tenant dev header fallback — only when NOT locked (WB_PUBLIC_BEARER
       unset) AND not multi-tenant. Safe for local dev; rejected on cloud.

  Assigns: `:identity` (%{user_id, tenant_id, session_id}) and `:tenant`.
  """
  import Plug.Conn
  @behaviour Plug

  alias Workbooks.Auth.Guardian

  @impl true
  def init(opts), do: opts

  # Public infra endpoints: liveness + the RCP handshake + DID doc. They carry no
  # tenant data and MUST answer in any mode (a client reads the capabilities doc
  # to learn the required auth rung BEFORE it has a credential).
  @public ~w(/health /.well-known/workbooks-runtime /.well-known/did.json /capabilities /api/capabilities)

  @impl true
  def call(conn, _opts) do
    cond do
      conn.request_path in @public -> dev_fallback(conn)
      # The groundskeeper bridge enforces its own credential (x-gk-secret /
      # the ElevenLabs webhook HMAC) and fails closed when unconfigured —
      # see Workbooks.Groundskeeper.Router.
      String.starts_with?(conn.request_path, "/gk/") -> dev_fallback(conn)
      true ->
        case bearer(conn) do
          nil -> no_bearer(conn)
          token -> verify(conn, token)
        end
    end
  end

  # No credential presented.
  # Locked deploy (WB_PUBLIC_BEARER set) → 401, no fallback — a missing token on
  # a public cloud endpoint is always unauthorized.
  # Multi-tenant (no lock) → 401, isolation can't rest on a spoofable header.
  # Dev/single-tenant (no lock) → x-tenant fallback.
  defp no_bearer(conn) do
    cond do
      locked?() -> Workbooks.Web.Error.render(conn, :unauthorized, "authentication required")
      Workbooks.Tenancy.multi?() -> Workbooks.Web.Error.render(conn, :tenant_required, "authentication required (multi-tenant)")
      true -> dev_fallback(conn)
    end
  end

  # Bearer presented — walk the ladder.
  defp verify(conn, token) do
    cond do
      # Desktop per-boot token (only when WB_DESKTOP=1).
      Workbooks.Desktop.enabled?() and Plug.Crypto.secure_compare(token, Workbooks.Desktop.token()) ->
        tenant = Workbooks.Desktop.tenant()
        assign_tenant(conn, tenant)

      # Shared-secret path: locked cloud deploy.
      locked?() ->
        verify_public_bearer(conn, token)

      # OIDC IdP (WorkOS/Clerk/Auth0/…) when the deployment configured one.
      Workbooks.OIDC.configured?() ->
        verify_oidc(conn, token)

      # BetterAuth JWT.
      true ->
        verify_jwt(conn, token)
    end
  end

  defp verify_oidc(conn, token) do
    case Workbooks.OIDC.verify_token(token) do
      {:ok, tenant} -> assign_tenant(conn, tenant)
      :error -> Workbooks.Web.Error.render(conn, :unauthorized, "unauthorized")
    end
  end

  defp verify_public_bearer(conn, token) do
    secret = System.get_env("WB_PUBLIC_BEARER")
    if Plug.Crypto.secure_compare(token, secret) do
      tenant = System.get_env("WB_TENANT", "local")
      assign_tenant(conn, tenant)
    else
      Workbooks.Web.Error.render(conn, :unauthorized, "unauthorized")
    end
  end

  defp verify_jwt(conn, token) do
    case Guardian.resource_from_token(token) do
      {:ok, identity, _claims} ->
        conn |> assign(:identity, identity) |> assign(:tenant, identity.tenant_id)

      {:error, _reason} ->
        Workbooks.Web.Error.render(conn, :unauthorized, "unauthorized")
    end
  end

  defp dev_fallback(conn) do
    tenant = conn |> get_req_header("x-tenant") |> List.first() || "dev"
    assign_tenant(conn, tenant)
  end

  defp assign_tenant(conn, tenant) do
    conn
    |> assign(:identity, %{user_id: tenant, tenant_id: tenant, session_id: nil})
    |> assign(:tenant, tenant)
  end

  # True when a shared-secret lock is in effect (WB_PUBLIC_BEARER is set and
  # non-empty). Cached per-process so the env is read only once per boot.
  defp locked? do
    case System.get_env("WB_PUBLIC_BEARER") do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp bearer(conn) do
    case conn |> get_req_header("authorization") |> List.first() do
      "Bearer " <> token -> token
      _ -> nil
    end
  end
end

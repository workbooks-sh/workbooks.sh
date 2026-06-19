defmodule Nexus.Auth do
  @moduledoc """
  The authentication + tenancy seam. A Plug that resolves each request to a **tenant** (and optional
  user) via a pluggable adapter, then assigns `:tenant` and `:identity`. The Store is partitioned by
  that tenant (`Nexus.Store`), so data isolation follows automatically — single-tenant and
  multi-tenant are the same machinery, single-tenant is just everyone on one tenant.

  Pick the adapter with `config :nexus, auth: …`:

    * `Nexus.Auth.None`   — DEFAULT. No auth; everyone is tenant `"default"` (local / single-tenant).
    * `Nexus.Auth.Bearer` — a shared `NEXUS_DATA_TOKEN` → a fixed `NEXUS_TENANT` (single-tenant lock).
    * `Nexus.Auth.Jwt`    — verify a Bearer JWT (HS256 secret OR RS256 via a JWKS url) and take the
      tenant from a configured claim. **One adapter for WorkOS / Clerk / Auth0 / BetterAuth / your
      own** — they all issue JWTs; you configure the `jwks_url`/`secret` + which claim is the tenant.

  An adapter just implements `authenticate/1`. Bring your own provider behind the same contract.
  """
  @behaviour Plug
  import Plug.Conn

  @type identity :: %{
          required(:tenant) => String.t(),
          optional(:user) => String.t() | nil,
          optional(:roles) => [String.t()],
          optional(:scopes) => [String.t()]
        }
  @callback authenticate(Plug.Conn.t()) :: {:ok, identity} | {:error, term}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  # Public, unauthenticated paths: `/health` (liveness — Fly/Docker/the daemon's first reach) and the
  # RCP capabilities handshake (the client fetches it BEFORE it has a token). Neither exposes tenant
  # data — the handshake reveals only how to authenticate.
  @public_paths ["/health", "/.well-known/workbooks-runtime"]
  def call(%{request_path: p} = conn, _opts) when p in @public_paths, do: conn
  # Login/callback endpoints are inherently public — they're how a request BECOMES authenticated.
  def call(%{request_path: "/auth/" <> _} = conn, _opts), do: conn

  def call(conn, _opts) do
    # Workbook-declared public globs skip auth entirely (login pages, marketing, etc.). When no `auth`
    # policy is declared this is always false, so behavior is unchanged from a no-guard deployment.
    if Nexus.Auth.Guard.public?(conn.method, conn.request_path) do
      conn
    else
      case adapter().authenticate(conn) do
        {:ok, %{tenant: tenant} = id} when is_binary(tenant) and tenant != "" ->
          conn = conn |> assign(:tenant, tenant) |> assign(:identity, id)

          # Per-route guard: :allow (default when no policy declared), 403 (wrong role/scope), or
          # 401 (the guard demands more than the adapter proved). Fail-closed by construction.
          case Nexus.Auth.Guard.decide(conn.method, conn.request_path, id) do
            :allow -> conn
            :forbidden -> conn |> send_resp(403, "forbidden") |> halt()
            :unauthenticated -> conn |> send_resp(401, "unauthorized") |> halt()
          end

        _ ->
          conn |> send_resp(401, "unauthorized") |> halt()
      end
    end
  end

  @doc "The configured auth adapter (default `Nexus.Auth.None`)."
  def adapter, do: Application.get_env(:nexus, :auth, Nexus.Auth.None)

  @doc "The request's tenant after the plug, or the default."
  def tenant(conn), do: conn.assigns[:tenant] || Nexus.Store.default_tenant()

  @doc "Whether this deployment is multi-tenant (any adapter but None)."
  def multi?, do: adapter() != Nexus.Auth.None
end

defmodule Nexus.Auth.None do
  @moduledoc "No auth — everyone is the default tenant. Local / single-tenant / dev (the default)."
  @behaviour Nexus.Auth

  @impl true
  def authenticate(_conn), do: {:ok, %{tenant: Nexus.Store.default_tenant(), user: nil}}
end

defmodule Nexus.Auth.Bearer do
  @moduledoc "Single-tenant lock — a shared `NEXUS_DATA_TOKEN` maps to a fixed `NEXUS_TENANT`."
  @behaviour Nexus.Auth
  import Plug.Conn, only: [get_req_header: 2]

  @impl true
  def authenticate(conn) do
    token = Nexus.Secrets.get("NEXUS_DATA_TOKEN")
    tenant = System.get_env("NEXUS_TENANT") || Nexus.Store.default_tenant()

    cond do
      token in [nil, ""] -> {:error, :no_token_configured}
      bearer_matches?(conn, token) -> {:ok, %{tenant: tenant, user: nil}}
      true -> {:error, :unauthorized}
    end
  end

  # Constant-time comparison of the presented bearer against the configured token. A plain `==` on
  # the token is a timing oracle that leaks the secret byte-by-byte; `secure_compare` is
  # constant-time. We compare the full expected `"Bearer <token>"` header value.
  defp bearer_matches?(conn, token) do
    expected = "Bearer " <> token

    case get_req_header(conn, "authorization") do
      [presented] -> Plug.Crypto.secure_compare(presented, expected)
      _ -> false
    end
  end
end

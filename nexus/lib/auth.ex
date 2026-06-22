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
      tenant from a configured claim. **One adapter for Clerk / Auth0 / your own IdP** — they all
      issue JWTs; you configure the `jwks_url`/`secret` + which claim is the tenant.

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
  # The git smart-HTTP endpoint does its OWN Basic-auth (PAT) inside Nexus.GitHttp (git clients speak
  # Basic, not Bearer/JWT). Skip the generic adapter so git can authenticate its own way.
  def call(%{request_path: "/git/" <> _} = conn, _opts), do: conn

  def call(conn, _opts) do
    # Workbook-declared public globs skip auth entirely (login pages, marketing, etc.). When no `auth`
    # policy is declared this is always false, so behavior is unchanged from a no-guard deployment.
    if Nexus.Auth.Guard.public?(conn.method, conn.request_path) do
      conn
    else
      case adapter().authenticate(conn) do
        # Valid session past its half-life → SLIDE it: re-issue the cookie so an active user is never
        # logged out mid-use, then proceed. (verify/3 flags this as :renew.)
        {:ok, %{tenant: tenant} = id, :renew} when is_binary(tenant) and tenant != "" ->
          conn |> Nexus.Auth.Session.issue(id) |> proceed(id)

        {:ok, %{tenant: tenant} = id} when is_binary(tenant) and tenant != "" ->
          proceed(conn, id)

        _ ->
          conn |> send_resp(401, "unauthorized") |> halt()
      end
    end
  end

  # Assign the identity + per-route guard. :allow → continue; 403/401 fail-closed.
  defp proceed(conn, %{tenant: tenant} = id) do
    conn = conn |> assign(:tenant, tenant) |> assign(:identity, id)

    case Nexus.Auth.Guard.decide(conn.method, conn.request_path, id) do
      :allow -> conn
      :forbidden -> conn |> send_resp(403, "forbidden") |> halt()
      :unauthenticated -> conn |> send_resp(401, "unauthorized") |> halt()
    end
  end

  @doc "The configured auth adapter (default `Nexus.Auth.None`)."
  def adapter, do: Application.get_env(:nexus, :auth, Nexus.Auth.None)

  @doc "The request's tenant after the plug, or the default."
  def tenant(conn), do: conn.assigns[:tenant] || Nexus.Store.default_tenant()

  @role_rank %{"viewer" => 1, "member" => 2, "admin" => 3, "owner" => 4}

  @doc """
  The session's effective role, SERVER-DERIVED from the authenticated identity (`conn.assigns.identity`)
  — never the client's word. Returns the highest-ranked role the user holds, defaulting to the least
  privilege (`"viewer"`) when there is no authenticated identity. This is the authority a handler must
  gate sensitive actions on (e.g. autopoet management is admin-only).
  """
  def role(conn) do
    identity = conn.assigns[:identity] || %{}
    session_roles = (identity[:roles] || []) |> Enum.map(&to_string/1)

    cond do
      # Sessions issued with roles (the fast path) — no DB hit.
      session_roles != [] -> Enum.max_by(session_roles, &Map.get(@role_rank, &1, 0), fn -> "viewer" end)
      # Sessions issued before roles were stored: derive from the DB by the session's user id, so an
      # existing login still resolves the right authority without forcing a re-login.
      is_binary(identity[:user]) -> Nexus.Auth.Accounts.role(identity[:user]) || "viewer"
      true -> "viewer"
    end
  end

  @doc "Does `role_name` meet or exceed `needed` in the role ranking (viewer<member<admin<owner)?"
  def role_at_least?(role_name, needed),
    do: Map.get(@role_rank, to_string(role_name), 0) >= Map.get(@role_rank, to_string(needed), 99)

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

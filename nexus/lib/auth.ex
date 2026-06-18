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

  @type identity :: %{required(:tenant) => String.t(), optional(:user) => String.t() | nil}
  @callback authenticate(Plug.Conn.t()) :: {:ok, identity} | {:error, term}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case adapter().authenticate(conn) do
      {:ok, %{tenant: tenant} = id} when is_binary(tenant) and tenant != "" ->
        conn |> assign(:tenant, tenant) |> assign(:identity, id)

      _ ->
        conn |> send_resp(401, "unauthorized") |> halt()
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
    token = System.get_env("NEXUS_DATA_TOKEN")
    tenant = System.get_env("NEXUS_TENANT") || Nexus.Store.default_tenant()

    cond do
      token in [nil, ""] -> {:error, :no_token_configured}
      get_req_header(conn, "authorization") == ["Bearer " <> token] -> {:ok, %{tenant: tenant, user: nil}}
      true -> {:error, :unauthorized}
    end
  end
end

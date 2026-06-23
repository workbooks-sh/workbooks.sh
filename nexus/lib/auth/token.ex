defmodule Nexus.Auth.Token do
  @moduledoc """
  Generic personal/API access tokens (`wbk_…`) for the native auth feature (RFC
  nexus/AUTH-ROUTING-RFC.md, epic wb-0uil). A token authenticates a **tenant** and carries **roles +
  scopes**, so the same Bearer flows feed the guard system (`protect … scope:/role:`). Use it for CLI
  access, agent-to-agent calls, CI — anything headless. The `Nexus.Auth.TokenBearer` adapter resolves
  a presented token to an identity.

  ## Security

    * **Hashed at rest** — only the token's SHA-256 hash is stored; the plaintext is shown ONCE by
      `mint/2` and is unrecoverable after. A leaked DB file yields no usable tokens.
    * **O(1) resolve** by hash; no tenant hint in the token, no scan.
    * **Audited** — `mint`/`revoke` emit a structured log event WITHOUT the plaintext.
    * Durable **SQLite** (`auth_tokens` in the Litestream-replicated `nexus.db`, via
      `Nexus.Auth.TokenStore`) — survives redeploys with no Fly volume.

  Generic + tenant-scoped: this is the standard's token primitive. (The control plane's
  `Nexus.ControlPlane.Token` shares the same `Nexus.Auth.TokenStore` backing.)
  """
  use GenServer
  require Logger
  alias Nexus.Auth.TokenStore

  @store :auth_tokens
  @prefix "wbk_"
  # Default token lifetime (90 days); see Nexus.ControlPlane.Token. A non-expiring credential maximizes
  # leak blast-radius (red-team wb-auph). New tokens carry an `expires_at`; verify refuses+revokes an
  # expired one. Override per-mint with `:ttl_seconds`/`:expires_at`. Legacy (no expires_at) = non-expiring.
  @default_ttl_seconds 90 * 24 * 60 * 60

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    TokenStore.ensure(@store)
    {:ok, %{}}
  end

  @doc """
  Mint a token for `tenant`. Opts: `:name`, `:scopes` (list), `:roles` (list). Returns
  `%{token: "wbk_…", id, name, scopes, created_at}` — the plaintext `token` is shown ONCE.
  """
  def mint(tenant, opts \\ []) when is_binary(tenant) and tenant != "" do
    token = @prefix <> rand(24)
    id = "tok_" <> rand(6)
    now = System.system_time(:second)

    expires_at = Keyword.get(opts, :expires_at, now + Keyword.get(opts, :ttl_seconds, @default_ttl_seconds))

    rec = %{
      tenant: tenant,
      id: id,
      name: to_string(opts[:name] || "token"),
      scopes: as_list(opts[:scopes]),
      roles: as_list(opts[:roles]),
      created_at: now,
      last_used_at: nil,
      expires_at: expires_at
    }

    TokenStore.ensure(@store)
    TokenStore.put(@store, hash(token), tenant, id, rec)
    Logger.info("[auth.token.mint] tenant=#{tenant} id=#{id} name=#{rec.name} scopes=#{inspect(rec.scopes)} roles=#{inspect(rec.roles)}")
    %{token: token, id: id, name: rec.name, scopes: rec.scopes, created_at: now, expires_at: expires_at}
  end

  @doc "Resolve a presented token → `{:ok, identity}` (tenant/user/roles/scopes) or `:error`."
  def verify(@prefix <> _ = token) do
    h = hash(token)
    TokenStore.ensure(@store)

    case TokenStore.get(@store, h) do
      {:ok, rec} ->
        now = System.system_time(:second)

        cond do
          expired?(rec, now) ->
            TokenStore.revoke(@store, rec.tenant, rec.id)
            :error

          true ->
            TokenStore.put(@store, h, rec.tenant, rec.id, %{rec | last_used_at: now})
            {:ok, %{tenant: rec.tenant, user: rec.id, roles: rec.roles, scopes: rec.scopes}}
        end

      _ ->
        :error
    end
  end

  def verify(_), do: :error

  # Legacy records (no expires_at) are non-expiring; a present expires_at is enforced.
  defp expired?(%{expires_at: exp}, now) when is_integer(exp), do: exp <= now
  defp expired?(_, _), do: false

  @doc "List a tenant's tokens (metadata only — never the plaintext or hash)."
  def list(tenant) when is_binary(tenant) do
    TokenStore.ensure(@store)

    TokenStore.list_scope(@store, tenant)
    |> Enum.map(&Map.drop(&1, [:tenant]))
    |> Enum.sort_by(& &1.created_at, :desc)
  end

  @doc "Revoke a tenant's token by id. Idempotent. Audited."
  def revoke(tenant, id) when is_binary(tenant) and is_binary(id) do
    TokenStore.ensure(@store)
    TokenStore.revoke(@store, tenant, id)
    Logger.info("[auth.token.revoke] tenant=#{tenant} id=#{id}")
    :ok
  end

  # ── internals ──
  defp rand(n), do: :crypto.strong_rand_bytes(n) |> Base.url_encode64(padding: false)
  defp hash(t), do: :crypto.hash(:sha256, t) |> Base.encode16(case: :lower)
  defp as_list(l) when is_list(l), do: Enum.map(l, &to_string/1)
  defp as_list(_), do: []
end

defmodule Nexus.Auth.TokenBearer do
  @moduledoc """
  Auth adapter that authenticates a `Authorization: Bearer wbk_…` token via `Nexus.Auth.Token` — opt
  in with `config :nexus, auth: Nexus.Auth.TokenBearer`. The resolved identity carries roles + scopes,
  so token callers are subject to the same per-route guards as session users.
  """
  @behaviour Nexus.Auth
  import Plug.Conn, only: [get_req_header: 2]

  @impl true
  def authenticate(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        case Nexus.Auth.Token.verify(String.trim(token)) do
          {:ok, identity} -> {:ok, identity}
          :error -> {:error, :unauthorized}
        end

      _ ->
        {:error, :unauthorized}
    end
  end
end

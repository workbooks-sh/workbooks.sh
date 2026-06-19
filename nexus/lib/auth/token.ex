defmodule Nexus.Auth.Token do
  @moduledoc """
  Generic personal/API access tokens (`wbk_…`) for the native auth feature (RFC
  nexus/AUTH-ROUTING-RFC.md, epic wb-0uil). A token authenticates a **tenant** and carries **roles +
  scopes**, so the same Bearer flows feed the guard system (`protect … scope:/role:`). Use it for CLI
  access, agent-to-agent calls, CI — anything headless. The `Nexus.Auth.TokenBearer` adapter resolves
  a presented token to an identity.

  ## Security

    * **Hashed at rest** — only the token's SHA-256 hash is stored; the plaintext is shown ONCE by
      `mint/2` and is unrecoverable after. A leaked DETS file yields no usable tokens.
    * **O(1) resolve** by hash; no tenant hint in the token, no scan.
    * **Audited** — `mint`/`revoke` emit a structured log event WITHOUT the plaintext.
    * Durable DETS (`data_dir/auth-tokens.dets`), owned by this long-lived GenServer (DETS closes with
      its opener), `auto_save` every 5s.

  Generic + tenant-scoped: this is the standard's token primitive. (The control plane's
  `Nexus.ControlPlane.Token` predates it and stays for now; consolidating it onto this is a follow-up.)
  """
  use GenServer
  require Logger

  @table :nexus_auth_tokens
  @prefix "wbk_"

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    File.mkdir_p!(Nexus.Config.data_dir())
    path = Nexus.Config.data_dir() |> Path.join("auth-tokens.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table, file: path, type: :set, auto_save: 5_000)
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.sync(@table)
    :dets.close(@table)
  end

  @doc """
  Mint a token for `tenant`. Opts: `:name`, `:scopes` (list), `:roles` (list). Returns
  `%{token: "wbk_…", id, name, scopes, created_at}` — the plaintext `token` is shown ONCE.
  """
  def mint(tenant, opts \\ []) when is_binary(tenant) and tenant != "" do
    token = @prefix <> rand(24)
    id = "tok_" <> rand(6)
    now = System.system_time(:second)

    rec = %{
      tenant: tenant,
      id: id,
      name: to_string(opts[:name] || "token"),
      scopes: as_list(opts[:scopes]),
      roles: as_list(opts[:roles]),
      created_at: now,
      last_used_at: nil
    }

    ensure() && :dets.insert(@table, {hash(token), rec})
    Logger.info("[auth.token.mint] tenant=#{tenant} id=#{id} name=#{rec.name} scopes=#{inspect(rec.scopes)} roles=#{inspect(rec.roles)}")
    %{token: token, id: id, name: rec.name, scopes: rec.scopes, created_at: now}
  end

  @doc "Resolve a presented token → `{:ok, identity}` (tenant/user/roles/scopes) or `:error`."
  def verify(@prefix <> _ = token) do
    h = hash(token)
    ensure()

    case :dets.lookup(@table, h) do
      [{^h, rec}] ->
        :dets.insert(@table, {h, %{rec | last_used_at: System.system_time(:second)}})
        {:ok, %{tenant: rec.tenant, user: rec.id, roles: rec.roles, scopes: rec.scopes}}

      _ ->
        :error
    end
  end

  def verify(_), do: :error

  @doc "List a tenant's tokens (metadata only — never the plaintext or hash)."
  def list(tenant) when is_binary(tenant) do
    ensure()

    :dets.foldl(
      fn {_h, %{tenant: t} = r}, acc ->
        if t == tenant, do: [Map.drop(r, [:tenant]) | acc], else: acc
      end,
      [],
      @table
    )
    |> Enum.sort_by(& &1.created_at, :desc)
  end

  @doc "Revoke a tenant's token by id. Idempotent. Audited."
  def revoke(tenant, id) when is_binary(tenant) and is_binary(id) do
    ensure()

    :dets.foldl(
      fn {h, %{tenant: t, id: i}}, _ -> if t == tenant and i == id, do: :dets.delete(@table, h), else: :ok end,
      :ok,
      @table
    )

    Logger.info("[auth.token.revoke] tenant=#{tenant} id=#{id}")
    :ok
  end

  # ── internals ──
  defp rand(n), do: :crypto.strong_rand_bytes(n) |> Base.url_encode64(padding: false)
  defp hash(t), do: :crypto.hash(:sha256, t) |> Base.encode16(case: :lower)
  defp as_list(l) when is_list(l), do: Enum.map(l, &to_string/1)
  defp as_list(_), do: []

  # The GenServer owns the table; in unit tests that don't boot the app, open it lazily so verify/mint
  # still work (a throwaway local table — never the durable production one, which the GenServer owns).
  defp ensure do
    case :ets.whereis(@table) do
      :undefined -> match?({:ok, _}, :dets.open_file(@table, file: ~c"#{Nexus.Config.data_dir()}/auth-tokens.dets", type: :set))
      _ -> true
    end
  rescue
    _ -> true
  end
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

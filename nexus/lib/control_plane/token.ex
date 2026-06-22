defmodule Nexus.ControlPlane.Token do
  @moduledoc """
  CLI personal-access tokens for the control plane. A user mints one in the
  dashboard (authenticated by their WorkOS JWT); the `work` CLI then sends it as
  `Authorization: Bearer wbk_…` and `Nexus.Auth.Cloud` resolves it to the org —
  the headless equivalent of the dashboard's JWT, so `work login` / `work deploy`
  work without a browser session.

  Durable **SQLite** table (`cp_tokens`) in the Litestream-replicated `nexus.db` (via
  `Nexus.Auth.TokenStore`), keyed by the token's SHA-256 **hash** (we never store the plaintext) →
  the record. `resolve/1` is an O(1) hash lookup. A long-lived GenServer ensures the table at boot.
  """
  use GenServer
  alias Nexus.Auth.TokenStore

  @store :cp_tokens
  @prefix "wbk_"

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    TokenStore.ensure(@store)
    {:ok, %{}}
  end

  @doc """
  Mint a token for `org`. Returns `%{token: "wbk_…", id, name, created_at}` — the
  plaintext `token` is shown ONCE (only its hash is stored). Subsequent reads
  never return it.

  A PAT inherits the **minting user's authority** so the headless CLI is not stuck
  at `viewer`: pass `role:` (the minter's server-derived role) and `user:` (the
  minter's id). `resolve/1` returns them and `Nexus.Auth.Cloud` surfaces them as
  the request identity. Defaults keep older callers working (`role: "member"`).
  """
  def mint(org, name \\ "cli", opts \\ []) when is_binary(org) and org != "" do
    secret = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    token = @prefix <> secret
    id = "tok_" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))
    now = System.system_time(:second)
    role = Keyword.get(opts, :role, "member") |> to_string()
    user = Keyword.get(opts, :user)
    TokenStore.put(@store, hash(token), org, id, %{org: org, id: id, name: to_string(name), role: role, user: user, created_at: now, last_used_at: nil})
    %{token: token, id: id, name: to_string(name), created_at: now}
  end

  @doc """
  Resolve a presented token (and bump last_used). `{:ok, %{org, role, user}}` — the
  org plus the minter's authority — or `:error` if unknown/not a PAT. Records
  predating role/user default to `role: "member"`, `user: nil`.
  """
  def resolve(@prefix <> _ = token) do
    h = hash(token)

    case TokenStore.get(@store, h) do
      {:ok, %{org: org} = rec} ->
        TokenStore.put(@store, h, org, rec.id, %{rec | last_used_at: System.system_time(:second)})
        {:ok, %{org: org, role: Map.get(rec, :role, "member"), user: Map.get(rec, :user)}}

      _ ->
        :error
    end
  end

  def resolve(_), do: :error

  @doc "List an org's tokens (metadata only — never the plaintext)."
  def list(org) when is_binary(org) do
    TokenStore.list_scope(@store, org)
    |> Enum.map(&Map.drop(&1, [:org]))
    |> Enum.sort_by(& &1.created_at, :desc)
  end

  @doc "Revoke an org's token by id. Idempotent."
  def revoke(org, id) when is_binary(org) and is_binary(id), do: TokenStore.revoke(@store, org, id)

  defp hash(t), do: :crypto.hash(:sha256, t) |> Base.encode16(case: :lower)
end

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
  # Default PAT lifetime (90 days). A non-expiring credential maximizes leak blast-radius (red-team
  # wb-auph): once leaked it grants org access forever until a human notices. New tokens carry an
  # `expires_at`; resolve refuses (and revokes) an expired one. Override per-mint with `:ttl_seconds`
  # or `:expires_at`. Legacy records with no `expires_at` are treated as non-expiring (back-compat).
  @default_ttl_seconds 90 * 24 * 60 * 60

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
    expires_at = Keyword.get(opts, :expires_at, now + Keyword.get(opts, :ttl_seconds, @default_ttl_seconds))
    TokenStore.put(@store, hash(token), org, id, %{org: org, id: id, name: to_string(name), role: role, user: user, created_at: now, last_used_at: nil, expires_at: expires_at})
    %{token: token, id: id, name: to_string(name), created_at: now, expires_at: expires_at}
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
        now = System.system_time(:second)

        cond do
          expired?(rec, now) ->
            # an expired token is dead: revoke it so the row can't be replayed, and refuse.
            TokenStore.revoke(@store, org, rec.id)
            :error

          true ->
            # row-guarded write-back: a concurrent revoke (DELETE) wins, never resurrected (wb-m6oz)
            TokenStore.touch(@store, h, %{rec | last_used_at: now})
            # Re-validate authority against the LIVE account: a user demoted since the token was minted
            # must not keep their old role via the frozen record. Effective role = the lower of the
            # minted role (a ceiling) and the user's current role. A token with no backing account row
            # (service/legacy) keeps the minted role; account REMOVAL is handled by explicit revoke. (wb-mjsz)
            {:ok, %{org: org, role: effective_role(Map.get(rec, :user), Map.get(rec, :role, "member")), user: Map.get(rec, :user)}}
        end

      _ ->
        :error
    end
  end

  # Legacy records (no expires_at) are non-expiring; a present expires_at is enforced.
  defp expired?(%{expires_at: exp}, now) when is_integer(exp), do: exp <= now
  defp expired?(_, _), do: false

  # The minted role is a CEILING; the live account role can only lower it (demotion takes effect). No
  # backing account (service/legacy token) ⇒ minted role unchanged.
  @rank %{"owner" => 3, "admin" => 2, "member" => 1, "viewer" => 0}
  defp effective_role(user, minted) when is_binary(user) do
    case Nexus.Auth.Accounts.role(user) do
      current when is_binary(current) -> if rank(current) < rank(minted), do: current, else: minted
      _ -> minted
    end
  end

  defp effective_role(_user, minted), do: minted
  defp rank(r), do: Map.get(@rank, to_string(r), 0)

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

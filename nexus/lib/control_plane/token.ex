defmodule Nexus.ControlPlane.Token do
  @moduledoc """
  CLI personal-access tokens for the control plane. A user mints one in the
  dashboard (authenticated by their WorkOS JWT); the `work` CLI then sends it as
  `Authorization: Bearer wbk_…` and `Nexus.Auth.Cloud` resolves it to the org —
  the headless equivalent of the dashboard's JWT, so `work login` / `work deploy`
  work without a browser session.

  Durable DETS table on the persistent volume (`data_dir/cp-tokens.dets`), keyed
  by the token's SHA-256 **hash** (we never store the plaintext) → the record. So
  `resolve/1` is an O(1) hash lookup with no scan and no org hint needed in the
  token. A long-lived GenServer owns the table (DETS closes when its opener dies).
  """
  use GenServer

  @table :nexus_cp_tokens
  @prefix "wbk_"

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    File.mkdir_p!(Nexus.Config.data_dir())
    path = Nexus.Config.data_dir() |> Path.join("cp-tokens.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table, file: path, type: :set, auto_save: 5_000)
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.sync(@table)
    :dets.close(@table)
  end

  @doc """
  Mint a token for `org`. Returns `%{token: "wbk_…", id, name, created_at}` — the
  plaintext `token` is shown ONCE (only its hash is stored). Subsequent reads
  never return it.
  """
  def mint(org, name \\ "cli") when is_binary(org) and org != "" do
    secret = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    token = @prefix <> secret
    id = "tok_" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))
    now = System.system_time(:second)
    :dets.insert(@table, {hash(token), %{org: org, id: id, name: to_string(name), created_at: now, last_used_at: nil}})
    %{token: token, id: id, name: to_string(name), created_at: now}
  end

  @doc "Resolve a presented token to its org (and bump last_used). `:error` if unknown/not a PAT."
  def resolve(@prefix <> _ = token) do
    h = hash(token)

    case :dets.lookup(@table, h) do
      [{^h, %{org: org} = rec}] ->
        :dets.insert(@table, {h, %{rec | last_used_at: System.system_time(:second)}})
        {:ok, org}

      _ ->
        :error
    end
  end

  def resolve(_), do: :error

  @doc "List an org's tokens (metadata only — never the plaintext)."
  def list(org) when is_binary(org) do
    :dets.foldl(
      fn {_h, %{org: o} = r}, acc ->
        if o == org, do: [Map.drop(r, [:org]) | acc], else: acc
      end,
      [],
      @table
    )
    |> Enum.sort_by(& &1.created_at, :desc)
  end

  @doc "Revoke an org's token by id. Idempotent."
  def revoke(org, id) when is_binary(org) and is_binary(id) do
    :dets.foldl(
      fn {h, %{org: o, id: i}}, _ -> if o == org and i == id, do: :dets.delete(@table, h), else: :ok end,
      :ok,
      @table
    )

    :ok
  end

  defp hash(t), do: :crypto.hash(:sha256, t) |> Base.encode16(case: :lower)
end

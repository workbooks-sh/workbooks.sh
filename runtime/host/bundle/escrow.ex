defmodule Workbooks.Bundle.Escrow do
  @moduledoc """
  The runtime-held content-key store (wb-v3w, the "real dead-man switch"). When
  `Bundle.ship` seals a gated entry, the plaintext AES-256-GCM content key is NOT
  written into the `.wbundle` — it is escrowed HERE, keyed by `key_id`, and the
  bundle carries only a `key_refs` reference. The runtime releases a key over RCP
  (`POST /rcp/key/:key_id`) ONLY after `Workbooks.Access.enforce` passes for the
  caller. The bundle is ciphertext + a manifest; without a release the gated bytes
  are noise.

  Storage is a self-starting public ETS table — the same lightweight runtime-held
  state the host already uses (Registry/ETS), NOT new persistence. The table is
  owned by a tiny dedicated process so it survives the call that created it; it is
  started lazily on first `put`/`get` so no supervision-tree wiring is required.
  """
  use GenServer

  @table __MODULE__

  # ── public api ───────────────────────────────────────────────────────────────

  @doc "Escrow `key` (32 bytes) under `key_id`. Overwrites a prior key for that id."
  def put(key_id, key) when is_binary(key_id) and is_binary(key) do
    ensure_started()
    :ets.insert(@table, {key_id, key})
    :ok
  end

  @doc "Fetch the escrowed key for `key_id`. `{:ok, key}` | `{:error, :no_such_key}`."
  def get(key_id) when is_binary(key_id) do
    ensure_started()

    case :ets.lookup(@table, key_id) do
      [{^key_id, key}] -> {:ok, key}
      [] -> {:error, :no_such_key}
    end
  end

  @doc "Forget an escrowed key (revocation). Idempotent."
  def delete(key_id) when is_binary(key_id) do
    ensure_started()
    :ets.delete(@table, key_id)
    :ok
  end

  @doc """
  A `Bundle.Sealed` keyfn (path → {key_id, key}) that mints a fresh content key
  per path AND escrows it, so the very act of sealing populates the runtime store.
  `prefix` (e.g. a workbook id) namespaces key_ids so two bundles don't collide.
  """
  def keyfn(prefix \\ "wb") do
    fn path ->
      key_id = prefix <> ":" <> Base.url_encode64(path, padding: false)
      key = Workbooks.Bundle.Sealed.generate_key()
      :ok = put(key_id, key)
      {key_id, key}
    end
  end

  # ── lazy self-start (no supervision-tree edit needed) ────────────────────────

  defp ensure_started do
    case :ets.whereis(@table) do
      :undefined ->
        case GenServer.start(__MODULE__, nil, name: __MODULE__) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        # the start above may race; wait until the table exists.
        wait_for_table()

      _ref ->
        :ok
    end
  end

  defp wait_for_table(tries \\ 100)
  defp wait_for_table(0), do: :ok

  defp wait_for_table(n) do
    case :ets.whereis(@table) do
      :undefined ->
        Process.sleep(1)
        wait_for_table(n - 1)

      _ ->
        :ok
    end
  end

  # ── genserver: owns the table so it outlives the creating call ───────────────

  @impl true
  def init(_) do
    @table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end

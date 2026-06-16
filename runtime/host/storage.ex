defmodule Workbooks.Storage do
  @moduledoc """
  Tenant-scoped BLOB storage — the BYOD seam. The runtime writes workbook bytes
  (`.wbundle`s, published artifacts, sealed blobs) through THIS interface; a
  deploy picks the backend with `WB_STORAGE` and implements it with an adapter.
  Add a provider = one module + one config line, never a runtime fork (the same
  pattern as the Browse provider slot).

  Tenant-scoped BY CONSTRUCTION: `tenant` is the first argument of every call, so
  isolation lives ABOVE the backend — swapping a Fly volume for R2 can't widen
  access. Auth (BetterAuth→Guardian) decides WHO the tenant is; this just stores
  their bytes under that scope. See docs/DEPLOY-KIT-STORAGE.md.
  """
  @callback put(tenant :: String.t(), key :: String.t(), bytes :: binary) :: :ok | {:error, term}
  @callback get(tenant :: String.t(), key :: String.t()) :: {:ok, binary} | :error
  @callback list(tenant :: String.t(), prefix :: String.t()) :: [String.t()]
  # delete must CONFIRM the backend removal (or report it was already gone); a
  # backend error must surface so the facade keeps the bytes charged (fail-closed).
  @callback delete(tenant :: String.t(), key :: String.t()) :: :ok | {:error, term}

  @doc "The configured adapter — `WB_STORAGE=local|s3` (default local)."
  def adapter do
    case System.get_env("WB_STORAGE", "local") do
      "s3" -> Workbooks.Storage.S3
      "r2" -> Workbooks.Storage.S3
      _ -> Workbooks.Storage.Local
    end
  end

  @doc """
  Store `bytes` for the tenant, enforcing the per-tenant TOTAL-BYTE quota
  (`WB_STORAGE_QUOTA_BYTES`, default ~5 GB — matching the dashboard's "5 GB
  included"). Fail-CLOSED: the byte ledger is reserved BEFORE the backend write, so
  we never partially write then fail; on a backend error the reservation is rolled
  back. Overwriting an existing key adjusts the counter by the DELTA, not the full
  new size. Returns `{:error, :quota_exceeded}` when the cap would be exceeded.
  """
  def put(tenant, key, bytes, opts \\ []) do
    with {:ok, tenant} <- safe_tenant(tenant),
         {:ok, key} <- ok_key(key) do
      new_size = byte_size(bytes)
      prior = Workbooks.Storage.Usage.prior_size(tenant, key)

      case Workbooks.Storage.Usage.reserve(tenant, key, new_size, opts) do
        :ok ->
          case adapter().put(tenant, key, bytes) do
            :ok ->
              :ok

            err ->
              # Backend write failed — restore the EXACT prior size (a failed
              # overwrite must not zero out the existing key's bytes).
              Workbooks.Storage.Usage.release(tenant, key, prior)
              err
          end

        {:error, _} = err ->
          err
      end
    end
  end

  def get(tenant, key) do
    # get returns {:ok, _} | :error — collapse any guard failure to :error.
    with {:ok, tenant} <- safe_tenant(tenant),
         {:ok, key} <- ok_key(key) do
      adapter().get(tenant, key)
    else
      _ -> :error
    end
  end

  def list(tenant, prefix \\ "") do
    case safe_tenant(tenant) do
      {:ok, tenant} -> adapter().list(tenant, prefix)
      {:error, _} -> []
    end
  end

  def delete(tenant, key) do
    with {:ok, tenant} <- safe_tenant(tenant),
         {:ok, key} <- ok_key(key) do
      # Fail-CLOSED: only forget the ledger row after a CONFIRMED backend delete.
      # On a backend error we KEEP the row (bytes stay charged) and surface it, so
      # a failed delete can never silently free quota.
      case adapter().delete(tenant, key) do
        :ok ->
          Workbooks.Storage.Usage.forget(tenant, key)
          :ok

        {:error, _} = err ->
          err
      end
    end
  end

  @doc "Current total bytes accounted for `tenant` (the quota ledger)."
  def usage_bytes(tenant), do: Workbooks.Storage.Usage.total(to_string(tenant))

  @doc "The per-tenant byte cap in effect (`WB_STORAGE_QUOTA_BYTES`, default ~5 GB)."
  def quota_bytes, do: Workbooks.Storage.Usage.quota()

  @doc """
  A time-limited presigned URL for a DIRECT browser upload/download to the object
  store (zero-egress). `dir` is `:put` or `:get`. Only the S3/R2 adapter supports
  this; the Local adapter returns `{:error, :unsupported}` (local dev uploads via
  `put/3`). Delegates to the adapter; the key is scoped to `<tenant>/blobs/`.

  A presigned PUT is a direct-to-R2 write that NEVER hits `put/3`, so the quota
  must be enforced HERE or it is an unmetered channel. The caller MUST declare the
  upload size via `:content_length`; we reserve those bytes up-front (fail-CLOSED →
  `{:error, :quota_exceeded}`) and the S3 adapter SIGNS the Content-Length header so
  R2 rejects an upload of a different size. Without `:content_length` we refuse to
  mint the URL (`{:error, :content_length_required}`) rather than leak an unmetered
  upload. `:get` (download) does not touch the quota.

  Phase-2 follow-up (tracked): reconcile the up-front reservation to the ACTUAL
  stored object size on upload completion (HEAD/webhook). Until then the up-front
  reservation is the fail-safe — it can over-count (a smaller upload than declared)
  but never under-count.
  """
  def presign(tenant, key, dir, opts \\ []) when dir in [:put, :get] do
    with {:ok, tenant} <- safe_tenant(tenant),
         {:ok, key} <- ok_key(key) do
      case {adapter(), dir} do
        {Workbooks.Storage.S3, :put} -> presign_put_metered(tenant, key, opts)
        {Workbooks.Storage.S3, :get} -> Workbooks.Storage.S3.presign_get(tenant, key, opts)
        {_, _} -> {:error, :unsupported}
      end
    end
  end

  # Reserve the DECLARED content-length before signing; on quota failure no URL is
  # minted. If signing itself fails, release the reservation so usage stays accurate.
  defp presign_put_metered(tenant, key, opts) do
    case Keyword.get(opts, :content_length) do
      n when is_integer(n) and n >= 0 ->
        prior = Workbooks.Storage.Usage.prior_size(tenant, key)

        case Workbooks.Storage.Usage.reserve(tenant, key, n, opts) do
          :ok ->
            case Workbooks.Storage.S3.presign_put(tenant, key, opts) do
              {:ok, _} = ok ->
                ok

              err ->
                Workbooks.Storage.Usage.release(tenant, key, prior)
                err
            end

          {:error, _} = err ->
            err
        end

      _ ->
        {:error, :content_length_required}
    end
  end

  # The tenant is the ISOLATION boundary, so it must be a single opaque segment —
  # never a path. Reject anything with "/", "..", or empty/whitespace-only so it
  # can't be normalized into another tenant's prefix (with a valid signature).
  @doc false
  def safe_tenant(tenant) do
    t = to_string(tenant)
    if Regex.match?(~r/^[A-Za-z0-9._-]+$/, t) and t not in [".", ".."], do: {:ok, t}, else: {:error, :invalid_tenant}
  end

  # Keys are relative paths under the tenant scope — never absolute, never `..`,
  # so a key can't escape its tenant prefix on a filesystem backend. Total over an
  # empty/dot-only key (which would crash `Path.join([])`) — return an error.
  @doc false
  def safe_key(key) do
    case key |> to_string() |> Path.split() |> Enum.reject(&(&1 in ["", ".", "..", "/"])) do
      [] -> {:error, :empty_key}
      parts -> {:ok, Path.join(parts)}
    end
  end

  # Facade-side key check, mapping the raw :empty_key to the caller-facing :invalid_key.
  defp ok_key(key) do
    case safe_key(key) do
      {:ok, k} -> {:ok, k}
      {:error, :empty_key} -> {:error, :invalid_key}
    end
  end
end

defmodule Workbooks.Storage.Usage do
  @moduledoc """
  Per-tenant byte-accounting ledger for the BLOB store quota. Reuses the SAME durable
  sqlite mechanism as `Workbooks.StorageBroker` (the host owns the DB; the tenant is
  always supplied by the host, never the guest), keeping a `(tenant, key) -> size`
  row per stored object so:

    * the per-tenant TOTAL is `SUM(size)` (one tenant's usage never touches another's),
    * an OVERWRITE adjusts by the DELTA (old size for the key is already counted),
    * a DELETE subtracts exactly that key's size,
    * `reserve/4` runs the cap check + insert in a SERIALIZED transaction, so
      concurrent puts cannot race past the cap (fail-closed under contention).
  """
  alias Exqlite.Sqlite3

  # ~5 GB — matches the dashboard's "5 GB included".
  @default_quota 5 * 1024 * 1024 * 1024

  @doc "The per-tenant byte cap (`WB_STORAGE_QUOTA_BYTES`, default ~5 GB)."
  def quota do
    case System.get_env("WB_STORAGE_QUOTA_BYTES") do
      nil -> @default_quota
      s -> case Integer.parse(s) do
              {n, _} when n >= 0 -> n
              _ -> @default_quota
            end
    end
  end

  @doc """
  Atomically: if counting `size` for `(tenant, key)` (delta-aware on overwrite) keeps
  the tenant at/under the cap, record it and return `:ok`; otherwise
  `{:error, :quota_exceeded}`. The cap check + write happen inside one serialized
  Agent call so concurrent puts cannot both pass a stale check.
  """
  def reserve(tenant, key, size, opts \\ []) do
    cap = Keyword.get(opts, :quota_bytes) || quota()
    call({:reserve, tenant, key, size, cap})
  end

  @doc """
  The size currently recorded for `(tenant, key)` (0 if absent). Callers capture
  this BEFORE `reserve/4` so a failed write can `release/3` the EXACT prior size
  back (a failed overwrite must not lose the existing key's bytes).
  """
  def prior_size(tenant, key), do: call({:prior_size, tenant, key})

  @doc """
  Undo a reservation (backend write failed) — restore the EXACT prior state. The
  reservation upserted the new size; release puts the key's PRIOR size back (or
  deletes the row if the key was genuinely new), so a failed OVERWRITE never loses
  the existing key's bytes. `prior` is the size returned by `reserve/4`.
  """
  def release(tenant, key, prior), do: call({:release, tenant, key, prior})

  @doc "Drop a key's accounting on delete (idempotent)."
  def forget(tenant, key), do: call({:forget, tenant, key})

  @doc "Current total bytes accounted for `tenant`."
  def total(tenant), do: call({:total, tenant})

  # ── ledger ops (run with the conn, serialized by the owning Agent) ────────────
  def open(path) do
    {:ok, conn} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS wb_storage_usage (
        tenant TEXT NOT NULL,
        key TEXT NOT NULL,
        size INTEGER NOT NULL,
        PRIMARY KEY (tenant, key)
      )
      """)

    {:ok, conn}
  end

  def do_reserve(conn, tenant, key, size, cap) do
    cur = sum(conn, tenant)
    prev = size_of(conn, tenant, key)
    next = cur - prev + size

    if next > cap do
      {:error, :quota_exceeded}
    else
      upsert(conn, tenant, key, size)
      :ok
    end
  end

  def do_release(conn, tenant, key, prior) do
    # Restore the EXACT prior state: if the key existed before (prior > 0) put its
    # old size back; if it was genuinely new (prior == 0) drop the row. A failed
    # OVERWRITE thus keeps the existing key charged at its real size, not 0.
    if prior > 0, do: upsert(conn, tenant, key, prior), else: del(conn, tenant, key)
    :ok
  end

  def do_prior_size(conn, tenant, key), do: size_of(conn, tenant, key)

  def do_forget(conn, tenant, key) do
    del(conn, tenant, key)
    :ok
  end

  defp sum(conn, tenant) do
    {:ok, stmt} =
      Sqlite3.prepare(conn, "SELECT COALESCE(SUM(size), 0) FROM wb_storage_usage WHERE tenant = ?1")

    :ok = Sqlite3.bind(stmt, [tenant])
    {:row, [n]} = Sqlite3.step(conn, stmt)
    Sqlite3.release(conn, stmt)
    n
  end

  defp size_of(conn, tenant, key) do
    {:ok, stmt} =
      Sqlite3.prepare(conn, "SELECT size FROM wb_storage_usage WHERE tenant = ?1 AND key = ?2")

    :ok = Sqlite3.bind(stmt, [tenant, key])

    res =
      case Sqlite3.step(conn, stmt) do
        {:row, [n]} -> n
        :done -> 0
      end

    Sqlite3.release(conn, stmt)
    res
  end

  defp upsert(conn, tenant, key, size) do
    {:ok, stmt} =
      Sqlite3.prepare(
        conn,
        "INSERT OR REPLACE INTO wb_storage_usage (tenant, key, size) VALUES (?1, ?2, ?3)"
      )

    :ok = Sqlite3.bind(stmt, [tenant, key, size])
    :done = Sqlite3.step(conn, stmt)
    Sqlite3.release(conn, stmt)
  end

  defp del(conn, tenant, key) do
    {:ok, stmt} =
      Sqlite3.prepare(conn, "DELETE FROM wb_storage_usage WHERE tenant = ?1 AND key = ?2")

    :ok = Sqlite3.bind(stmt, [tenant, key])
    :done = Sqlite3.step(conn, stmt)
    Sqlite3.release(conn, stmt)
  end

  # Route every op through the serializing Agent (single sqlite writer) so the
  # check-then-write in reserve/4 is atomic against concurrent callers.
  defp call(msg), do: Workbooks.Storage.Usage.Server.run(msg)
end

defmodule Workbooks.Storage.Usage.Server do
  @moduledoc """
  Serializes access to the storage-usage ledger (sqlite is single-writer), exactly
  like `Workbooks.StorageBroker.Server`. Lazily opened; the durable file defaults to
  the same KV db dir (`WB_STORAGE_USAGE_DB`). The TENANT is always host-supplied.
  """
  use Agent
  alias Workbooks.Storage.Usage

  def start_link(opts \\ []) do
    path = Keyword.get(opts, :path, db_path())
    Agent.start_link(fn -> elem(Usage.open(path), 1) end, name: __MODULE__)
  end

  @doc false
  # Test seam: (re)start the singleton against a fresh `path` so a test gets an
  # isolated ledger. Never called in production (the lazy `conn/0` path is used).
  def reset_for_test!(path) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end

    {:ok, _} = start_link(path: path)
    :ok
  end

  defp db_path, do: System.get_env("WB_STORAGE_USAGE_DB", Path.join(System.tmp_dir!(), "wb_storage_usage.db"))

  defp conn do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        Process.whereis(__MODULE__)

      pid ->
        pid
    end
  end

  @doc false
  def run(msg) do
    Agent.get(conn(), fn c -> dispatch(c, msg) end, 15_000)
  end

  defp dispatch(c, {:reserve, t, k, s, cap}), do: Usage.do_reserve(c, t, k, s, cap)
  defp dispatch(c, {:release, t, k, p}), do: Usage.do_release(c, t, k, p)
  defp dispatch(c, {:forget, t, k}), do: Usage.do_forget(c, t, k)
  defp dispatch(c, {:prior_size, t, k}), do: Usage.do_prior_size(c, t, k)
  defp dispatch(c, {:total, t}), do: total(c, t)

  defp total(conn, tenant) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(conn, "SELECT COALESCE(SUM(size), 0) FROM wb_storage_usage WHERE tenant = ?1")

    :ok = Exqlite.Sqlite3.bind(stmt, [tenant])
    {:row, [n]} = Exqlite.Sqlite3.step(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
    n
  end
end

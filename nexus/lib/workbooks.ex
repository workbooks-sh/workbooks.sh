defmodule Nexus.Workbooks do
  @moduledoc """
  The local workbook library — `~/.workbooks/` — and the dev faked-backend that stands in for the
  production data stores so a workbook persists with **zero infra** locally.

  A workbook declares *methods* for its data: `postgres` (structured rows), `r2`/s3 (objects), or
  `sqlite` (data shipped WITH the workbook — demo/VFS/cold, never the prod store). Those same
  declarations resolve to **real** Neon + R2 in production (picked by injected secrets), and to a
  faked local backend in dev:

      ~/.workbooks/
        registry.db        — the managed workbook ↔ UUID map (assigned on first run)
        dev/
          db/<uuid>/store.db — faked Postgres   (a SQLite stand-in, per workbook)
          s3/<uuid>/         — faked R2 bucket   (a folder, per workbook)

  Each workbook that runs through the nexus is assigned a stable UUID, recorded in the registry, so
  its db + bucket are heavily managed and dev/demo data can never reach a production store. Override
  the library root with `WB_HOME` (a per-machine path).
  """

  alias Exqlite.Sqlite3

  @doc "The workbook library root (`$WB_HOME`, default `~/.workbooks`)."
  def home, do: System.get_env("WB_HOME") || Path.expand("~/.workbooks")

  @doc """
  True for any non-local-dev runtime — the dev faked per-workbook backend is bypassed in favor of the
  managed durable one (resources → the volume `nexus.db`, blobs → the durable object store). A deployed
  **release** (RELEASE_NAME) always counts, not just when cloud secrets happen to be present — otherwise
  a serving nexus silently writes resources/blobs to ephemeral `~/.workbooks/dev/*` and loses them on
  restart (the same ephemeral-vs-durable drift that wiped the accounts DB).
  """
  def prod?,
    do:
      present?(System.get_env("RELEASE_NAME")) or present?(System.get_env("WB_DATABASE_URL")) or
        present?(System.get_env("WB_S3_BUCKET"))

  @doc "True in the test environment (where each test owns its data backend explicitly)."
  def test?, do: function_exported?(Mix, :env, 0) and Mix.env() == :test

  @doc """
  The UUID for a workbook (by its root path key), assigning + recording one on first run. Stable
  across runs; the managed registry makes the mapping inspectable.
  """
  def uuid_for(key) when is_binary(key) do
    key = Path.expand(key)

    with_registry(fn conn ->
      case fetch(conn, key) do
        nil ->
          uuid = new_uuid()
          name = Path.basename(key)
          {:ok, stmt} = Sqlite3.prepare(conn, "INSERT INTO workbooks (key, uuid, name, created) VALUES (?1,?2,?3,?4)")
          :ok = Sqlite3.bind(stmt, [key, uuid, name, DateTime.utc_now() |> DateTime.to_iso8601()])
          :done = Sqlite3.step(conn, stmt)
          uuid

        uuid ->
          uuid
      end
    end)
  end

  @doc "The dev faked-Postgres SQLite file for a workbook UUID (parents created)."
  def dev_db_path(uuid) do
    dir = Path.join([home(), "dev", "db", uuid])
    File.mkdir_p!(dir)
    Path.join(dir, "store.db")
  end

  @doc "The dev faked-R2 bucket directory for a workbook UUID (created)."
  def dev_s3_dir(uuid) do
    dir = Path.join([home(), "dev", "s3", uuid])
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Resolve + install the data backend for the workbook served from `root`. In dev this points
  `Nexus.Store` at the workbook's own SQLite under `~/.workbooks/dev/db/<uuid>` (durable, survives a
  restart); in prod (secrets injected) it leaves the configured cloud adapter untouched. Returns the
  resolved `%{uuid, db, bucket}` or `nil` in prod.
  """
  def install_dev_backend(root) do
    if prod?() or test?() do
      # prod: injected cloud secrets own the backend. test: each test controls its own backend
      # explicitly (default ETS), so we must never mutate the global :store_adapter from here —
      # doing so leaks the per-workbook SQLite across the async:false suite.
      nil
    else
      uuid = uuid_for(root)
      db = dev_db_path(uuid)
      bucket = dev_s3_dir(uuid)
      Application.put_env(:nexus, :store_adapter, Nexus.Store.Sqlite)
      Application.put_env(:nexus, :sqlite_path, db)
      Application.put_env(:nexus, :s3_local_dir, bucket)
      %{uuid: uuid, db: db, bucket: bucket}
    end
  end

  # ── registry (a small managed SQLite at ~/.workbooks/registry.db) ──────────────────────────────

  defp with_registry(fun) do
    File.mkdir_p!(home())
    {:ok, conn} = Sqlite3.open(Path.join(home(), "registry.db"))

    try do
      Sqlite3.execute(conn, "CREATE TABLE IF NOT EXISTS workbooks (key TEXT PRIMARY KEY, uuid TEXT, name TEXT, created TEXT)")
      fun.(conn)
    after
      Sqlite3.close(conn)
    end
  end

  defp fetch(conn, key) do
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT uuid FROM workbooks WHERE key = ?1")
    :ok = Sqlite3.bind(stmt, [key])

    case Sqlite3.step(conn, stmt) do
      {:row, [uuid]} -> uuid
      _ -> nil
    end
  end

  defp new_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e]) |> to_string()
  end

  defp present?(v), do: is_binary(v) and v != ""
end

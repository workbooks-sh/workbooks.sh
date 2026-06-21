defmodule Nexus.Sessions do
  @moduledoc """
  Persisted swarm sessions — a SQLite history living in the workbook's data dir (`sessions.db` under
  `Nexus.Config.data_dir/0`). Each completed fleet run is saved (query, agent count, the per-agent
  findings, the final report, timestamp) so past sessions can be revisited. A connection is opened
  per call (and closed) — simple and safe for the demo's write rate.
  """
  alias Exqlite.Sqlite3

  @doc "Persist a completed session. Returns :ok (best-effort — never raises into the fleet)."
  def save(%{} = s) do
    with_conn(fn conn ->
      {:ok, stmt} =
        Sqlite3.prepare(conn, "INSERT INTO sessions (query, agents, report, findings, created_at) VALUES (?1,?2,?3,?4,?5)")

      :ok = Sqlite3.bind(stmt, [s.query, s.agents, s.report, Jason.encode!(s.findings || []), now()])
      :done = Sqlite3.step(conn, stmt)
      Sqlite3.release(conn, stmt)
      :ok
    end)
  end

  @doc "Recent sessions (newest first) — id/query/agents/created_at, for the history list."
  def list(limit \\ 50) do
    with_conn(fn conn ->
      {:ok, stmt} = Sqlite3.prepare(conn, "SELECT id, query, agents, created_at FROM sessions ORDER BY id DESC LIMIT ?1")
      :ok = Sqlite3.bind(stmt, [limit])
      {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
      Sqlite3.release(conn, stmt)
      Enum.map(rows, fn [id, q, a, t] -> %{id: id, query: q, agents: a, created_at: t} end)
    end) || []
  end

  @doc "One full session (report + findings) by id, or nil."
  def get(id) do
    with_conn(fn conn ->
      {:ok, stmt} = Sqlite3.prepare(conn, "SELECT id, query, agents, report, findings, created_at FROM sessions WHERE id = ?1")
      :ok = Sqlite3.bind(stmt, [id])
      {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
      Sqlite3.release(conn, stmt)

      case rows do
        [[id, q, a, r, f, t]] -> %{id: id, query: q, agents: a, report: r, findings: decode(f), created_at: t}
        _ -> nil
      end
    end)
  end

  defp decode(f) do
    case Jason.decode(f || "[]") do
      {:ok, v} -> v
      _ -> []
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp with_conn(fun) do
    {:ok, conn} = Sqlite3.open(db_path())

    Sqlite3.execute(
      conn,
      "CREATE TABLE IF NOT EXISTS sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, query TEXT, agents INTEGER, report TEXT, findings TEXT, created_at TEXT)"
    )

    try do
      fun.(conn)
    after
      Sqlite3.close(conn)
    end
  rescue
    # Sessions are best-effort history — never crash a fleet run on a session write. But LOG it (don't
    # swallow silently) so a real failure (e.g. SQLITE_FULL — a full volume) is visible, not invisible.
    e ->
      require Logger
      Logger.warning("[sessions] db op failed (non-fatal): #{Exception.message(e)}")
      nil
  end

  # Sessions live in the ONE durable DB (Nexus.Paths.db_path → volume + Litestream), as their own
  # table — not a separate `sessions.db`, which sat on ephemeral storage and was lost on every restart.
  defp db_path, do: Nexus.Paths.db_path()
end

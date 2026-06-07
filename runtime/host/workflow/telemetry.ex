defmodule Workbooks.Workflow.Telemetry do
  @moduledoc """
  Always-on observability for a workflow run — the SQLite half of the split
  (scratch = org files for the agent's thinking; telemetry = SQLite for the
  structured record). Every `Workbooks.Workflow.Todo` run persists one
  `_telemetry.db` in its workdir: a queryable log of every task's final state,
  output, and timestamp. Structured + aggregatable (pass/fail rates, per-run
  history) in a way free-form org never is.

  Single-writer: the executor hands the finished task records here at run-end, so
  there's no cross-process SQLite contention. A run can keep multiple of these
  (one per workdir) so each session's logs are preserved + independently
  queryable; nothing is overwritten.
  """
  alias Exqlite.Sqlite3

  @doc "Persist task records for `run_id` into `<workdir>/_telemetry.db`. Best-effort."
  def persist(workdir, run_id, tasks) do
    path = Path.join(workdir, "_telemetry.db")
    {:ok, c} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(c, """
      CREATE TABLE IF NOT EXISTS task_events (
        run_id TEXT, task_id TEXT, idx INTEGER, title TEXT,
        state TEXT, output TEXT, ts INTEGER
      )
      """)

    for t <- tasks do
      {:ok, stmt} = Sqlite3.prepare(c, "INSERT INTO task_events VALUES (?1,?2,?3,?4,?5,?6,?7)")
      :ok = Sqlite3.bind(stmt, [run_id, t.id, t.idx, t.title, t.state, t[:output] || "", t[:ts] || now()])
      :done = Sqlite3.step(c, stmt)
      Sqlite3.release(c, stmt)
    end

    Sqlite3.close(c)
    :ok
  rescue
    _ -> :error
  end

  @doc "Query the telemetry db → task event rows (maps). For observability."
  def events(workdir) do
    path = Path.join(workdir, "_telemetry.db")
    {:ok, c} = Sqlite3.open(path)
    {:ok, stmt} = Sqlite3.prepare(c, "SELECT run_id, task_id, idx, title, state, ts FROM task_events ORDER BY ts, idx")
    {:ok, rows} = Sqlite3.fetch_all(c, stmt)
    Sqlite3.release(c, stmt)
    Sqlite3.close(c)

    Enum.map(rows, fn [run_id, task_id, idx, title, state, ts] ->
      %{run_id: run_id, task_id: task_id, idx: idx, title: title, state: state, ts: ts}
    end)
  rescue
    _ -> []
  end

  defp now, do: System.system_time(:second)
end

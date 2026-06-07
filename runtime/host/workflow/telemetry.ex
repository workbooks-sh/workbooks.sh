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

    ingest_steps(c, run_id, workdir)
    Sqlite3.close(c)
    :ok
  rescue
    _ -> :error
  end

  # Ingest the always-on _steps.jsonl (every tool call, captured at the chokepoint
  # in Workbooks.Agent) into step_events — the per-tool record: tool, exit_code,
  # error, duration. This is how "a bash call broke" is queryable after the fact.
  defp ingest_steps(c, run_id, workdir) do
    Sqlite3.execute(c, """
    CREATE TABLE IF NOT EXISTS step_events (
      run_id TEXT, step INTEGER, tool TEXT, exit_code INTEGER,
      error TEXT, dur_ms INTEGER, ts INTEGER
    )
    """)

    case File.read(Path.join(workdir, "_steps.jsonl")) do
      {:ok, body} ->
        for line <- String.split(body, "\n", trim: true) do
          case Jason.decode(line) do
            {:ok, e} ->
              {:ok, stmt} = Sqlite3.prepare(c, "INSERT INTO step_events VALUES (?1,?2,?3,?4,?5,?6,?7)")
              Sqlite3.bind(stmt, [run_id, e["step"], e["tool"], e["exit_code"], e["error"], e["dur_ms"], e["ts"]])
              Sqlite3.step(c, stmt)
              Sqlite3.release(c, stmt)

            _ -> :skip
          end
        end

      _ -> :ok
    end
  end

  @doc """
  Observability summary for a run — the CLI feedback loop. Returns task states,
  tool-call counts, errors (bash exits / tool failures), and total step time.
  """
  def summary(workdir) do
    path = Path.join(workdir, "_telemetry.db")
    {:ok, c} = Sqlite3.open(path)

    steps = q(c, "SELECT step, tool, exit_code, error, dur_ms FROM step_events ORDER BY step")
    tasks = q(c, "SELECT task_id, state FROM task_events ORDER BY idx")
    Sqlite3.close(c)

    errors =
      Enum.filter(steps, fn [_s, _t, code, err, _d] -> (code && code != 0) || err end)
      |> Enum.map(fn [s, t, code, err, _d] -> %{step: s, tool: t, exit_code: code, error: err} end)

    %{
      tasks: Enum.map(tasks, fn [id, st] -> %{id: id, state: st} end),
      tool_calls: length(steps),
      total_ms: Enum.reduce(steps, 0, fn [_, _, _, _, d], a -> a + (d || 0) end),
      errors: errors
    }
  rescue
    _ -> %{error: "no telemetry"}
  end

  defp q(c, sql) do
    {:ok, stmt} = Sqlite3.prepare(c, sql)
    {:ok, rows} = Sqlite3.fetch_all(c, stmt)
    Sqlite3.release(c, stmt)
    rows
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

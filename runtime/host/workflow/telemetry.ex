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
  Observability summary for a run — the CLI feedback loop. UNIVERSAL + LIVE:
  reads the always-on `_steps.jsonl` (written at the agent chokepoint by EVERY
  exec agent — workflow, brandnana, free-form ask), so any run is observable even
  mid-flight and even without a persisted db. Tasks/stage come from `_status.json`.
  Returns tool-call count, errors (bash exits / tool failures), total step time,
  the recent tool timeline, and the run stage.
  """
  def summary(workdir) do
    steps = read_steps(workdir)
    status = read_status(workdir)

    errors =
      steps
      |> Enum.filter(fn s -> (s["exit_code"] && s["exit_code"] != 0) || s["error"] end)
      |> Enum.map(fn s -> %{step: s["step"], tool: s["tool"], exit_code: s["exit_code"], error: s["error"]} end)

    if steps == [] and status == %{} do
      %{error: "no telemetry for this run"}
    else
      %{
        stage: status["stage"],
        tasks: status["tasks"] || [],
        tool_calls: length(steps),
        total_ms: Enum.reduce(steps, 0, fn s, a -> a + (s["dur_ms"] || 0) end),
        errors: errors,
        recent: steps |> Enum.take(-15) |> Enum.map(&Map.take(&1, ["step", "tool", "exit_code", "dur_ms"]))
      }
    end
  rescue
    _ -> %{error: "no telemetry"}
  end

  @runs_base "/tmp/bb"

  @doc """
  Cross-session index (0d) — every run under the base, newest first, each rolled
  up to stage + tool-call count + error count + duration. The "see across runs"
  view: spot a regression (errors climbing run-over-run), not just one run in
  isolation. Pure scan over the same always-on `_steps.jsonl`/`_status.json` —
  no extra writes, so it's free and can't drift from the per-run truth.
  """
  def index(base \\ @runs_base, limit \\ 50) do
    case File.ls(base) do
      {:ok, slugs} ->
        slugs
        |> Enum.map(fn slug ->
          wd = Path.join(base, slug)
          s = summary(wd)
          %{slug: slug, stage: s[:stage], tool_calls: s[:tool_calls] || 0,
            errors: length(s[:errors] || []), total_ms: s[:total_ms] || 0, mtime: mtime(wd)}
        end)
        |> Enum.reject(&(&1.tool_calls == 0 and is_nil(&1.stage)))
        |> Enum.sort_by(& &1.mtime, :desc)
        |> Enum.take(limit)

      _ -> []
    end
  end

  # Run recency = the last time its always-on step log was touched (falls back to
  # the dir itself for runs that never logged a step).
  defp mtime(wd) do
    case File.stat(Path.join(wd, "_steps.jsonl"), time: :posix) do
      {:ok, %{mtime: m}} -> m
      _ -> case File.stat(wd, time: :posix), do: ({:ok, %{mtime: m}} -> m; _ -> 0)
    end
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

  # The always-on per-tool log — the universal source (every exec agent writes it).
  defp read_steps(workdir) do
    case File.read(Path.join(workdir, "_steps.jsonl")) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line -> case Jason.decode(line), do: ({:ok, m} -> [m]; _ -> []) end)

      _ -> []
    end
  end

  defp read_status(workdir) do
    case File.read(Path.join(workdir, "_status.json")) do
      {:ok, body} -> case Jason.decode(body), do: ({:ok, m} -> m; _ -> %{})
      _ -> %{}
    end
  end

  defp now, do: System.system_time(:second)
end

defmodule Workbooks.SessionLedger do
  @moduledoc """
  Append-only session metadata ledger (wb-kbq5 / wb-t3mr) — the source for the
  desktop's session list + navigation. AgentSessions are in-memory (a Registry),
  so a finished run's metadata would vanish; we record a one-line JSON entry per
  run on start so the desktop can browse PAST conversations, not just live ones.

  Each entry: {session_id, agent_slug, prompt_preview, workdir, started_at}. The
  live `status`/`finished_at` are folded in at read time from the running
  AgentSession (if still registered) — else the run is treated as completed.
  """
  require Logger

  defp path, do: Path.join(System.get_env("WB_DATA") || System.tmp_dir!(), "wb-sessions.jsonl")

  @doc "Record a session at start. Best-effort — never breaks the run."
  def record(session_id, agent_slug, prompt, workdir) do
    entry = %{
      session_id: session_id,
      agent_slug: agent_slug,
      prompt_preview: prompt |> to_string() |> String.slice(0, 120),
      workdir: workdir,
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write(path(), Jason.encode!(entry) <> "\n", [:append])
  rescue
    _ -> :ok
  end

  @doc """
  List sessions, newest first, each as a desktop SessionRow. `active_only?`
  narrows to currently-running ones.
  """
  def list(active_only? \\ false) do
    case File.read(path()) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.map(&decode/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.reverse()
        |> Enum.map(&fold_live_status/1)
        |> dedupe_by_id()
        |> then(&if active_only?, do: Enum.filter(&1, fn r -> r.status == "running" end), else: &1)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp decode(line) do
    Jason.decode!(line)
  rescue
    _ -> nil
  end

  # Enrich the recorded metadata with the live run status (running/done) +
  # finished_at. A run no longer in the Registry is treated as completed.
  defp fold_live_status(%{"session_id" => id} = e) do
    {status, finished_at} =
      case Workbooks.AgentSession.status(id) do
        %{status: :done} -> {"completed", e["started_at"]}
        %{status: s} -> {to_string(s), nil}
        _ -> {"completed", e["started_at"]}
      end

    %{
      session_id: id,
      agent_slug: e["agent_slug"],
      prompt_preview: e["prompt_preview"],
      workdir: e["workdir"],
      status: status,
      started_at: e["started_at"],
      finished_at: finished_at
    }
  end

  # Keep only the newest entry per session_id (a re-run reuses no id, but guard).
  defp dedupe_by_id(rows) do
    rows
    |> Enum.reduce({[], MapSet.new()}, fn r, {acc, seen} ->
      if MapSet.member?(seen, r.session_id), do: {acc, seen}, else: {[r | acc], MapSet.put(seen, r.session_id)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end

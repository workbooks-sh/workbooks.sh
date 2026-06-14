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

  @doc "Record a session at start. Best-effort — never breaks the run. `tenant` scopes visibility (wb-g1yo.1)."
  def record(session_id, agent_slug, prompt, workdir, tenant \\ nil) do
    entry = %{
      session_id: session_id,
      agent_slug: agent_slug,
      prompt_preview: prompt |> to_string() |> String.slice(0, 120),
      workdir: workdir,
      tenant: tenant,
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write(path(), Jason.encode!(entry) <> "\n", [:append])
  rescue
    _ -> :ok
  end

  @doc """
  List sessions visible to `tenant`, newest first, each as a desktop SessionRow.
  `tenant` (wb-g1yo.1) scopes the result: an entry is shown only to its own
  tenant. Legacy entries with no recorded tenant (pre-scoping, which only exist
  in single-tenant deployments) are grandfathered visible to all. Pass `nil` to
  see everything (an admin/internal view — wb-g1yo.5). `active_only?` narrows to
  running runs.
  """
  def list(tenant \\ nil, active_only? \\ false) do
    case File.read(path()) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.map(&decode/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.reverse()
        |> Enum.map(&fold_live_status/1)
        |> dedupe_by_id()
        |> scope_to_tenant(tenant)
        |> then(&if active_only?, do: Enum.filter(&1, fn r -> r.status == "running" end), else: &1)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  # nil tenant = no scoping (admin/internal). Otherwise show only this tenant's
  # rows + legacy rows that predate scoping (tenant == nil on the entry).
  defp scope_to_tenant(rows, nil), do: rows

  defp scope_to_tenant(rows, tenant),
    do: Enum.filter(rows, fn r -> r.tenant in [nil, tenant] end)

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
      tenant: e["tenant"],
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

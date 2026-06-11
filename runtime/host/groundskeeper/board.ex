defmodule Workbooks.Groundskeeper.Board do
  @moduledoc """
  BOARD.org — the git-visible single source of truth (wb-3ojf.3).

  bd is the operational ledger but lives outside git forever (.beads is a
  public-repo liability, settled 2026-06-09). So after every conversation the
  groundskeeper regenerates BOARD.org FROM bd — one direction of flow, never
  hand-edited, no two-way sync — and (when WB_GK_AUTOCOMMIT=1) commits it
  together with the conversation's other artifacts (captures, transcripts,
  TASKS.org). Claude Code reads BOARD.org at session start; the git log is
  its history.
  """
  require Logger
  alias Workbooks.Groundskeeper

  @doc "Regenerate BOARD.org from bd. Returns {:ok, path} | {:error, _}."
  def sync do
    with {:ok, issues} <- bd_json() do
      path = Path.join(Groundskeeper.home(), "BOARD.org")
      File.write!(path, render(issues))
      {:ok, path}
    end
  end

  @doc "Sync, then commit the groundskeeper's artifacts (opt-in: WB_GK_AUTOCOMMIT=1)."
  def sync_and_commit do
    result = sync()

    if System.get_env("WB_GK_AUTOCOMMIT") == "1" do
      home = Groundskeeper.home()

      with {_, 0} <- git(["add", home]),
           {out, code} <- git(["commit", "-m", "groundskeeper: board + sources sync"]) do
        if code == 0,
          do: git(["push"]),
          else: Logger.info("gk board commit: #{String.trim(out)}")
      end
    end

    result
  end

  defp render(issues) do
    open = Enum.filter(issues, &(&1["status"] in ["open", "in_progress", "deferred"]))
    closed = issues |> Enum.filter(&(&1["status"] == "closed")) |> recent("closed_at", 15)
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M UTC")

    by_priority =
      open
      |> Enum.group_by(& &1["priority"])
      |> Enum.sort_by(fn {p, _} -> p end)
      |> Enum.map(fn {p, items} ->
        lines = items |> Enum.sort_by(& &1["updated_at"], :desc) |> Enum.map(&headline/1) |> Enum.join("\n")
        "* P#{p} (#{length(items)})\n#{lines}"
      end)
      |> Enum.join("\n\n")

    """
    #+TITLE: BOARD — the repo, as bd sees it
    #+GENERATED: [#{stamp}] by Workbooks.Groundskeeper.Board — NEVER hand-edit (regenerated from bd; bd stays out of git)
    #+TODO: TODO DOING DEFERRED | DONE

    #{by_priority}

    * recently closed
    #{closed |> Enum.map(&headline/1) |> Enum.join("\n")}
    """
  end

  defp headline(issue) do
    kw =
      case issue["status"] do
        "in_progress" -> "DOING"
        "deferred" -> "DEFERRED"
        "closed" -> "DONE"
        _ -> "TODO"
      end

    type = if issue["issue_type"] in ["epic"], do: " :epic:", else: ""
    "** #{kw} #{issue["title"]}#{type}\n   :ID: #{issue["id"]}"
  end

  defp recent(items, field, n) do
    items |> Enum.sort_by(& &1[field], :desc) |> Enum.take(n)
  end

  defp bd_json do
    case System.cmd("bd", ["list", "--json", "--all", "--flat"], stderr_to_stdout: true) do
      {out, 0} -> Jason.decode(out)
      {out, _} -> {:error, String.slice(out, 0, 200)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp git(args) do
    System.cmd("git", args, stderr_to_stdout: true, cd: Groundskeeper.home())
  rescue
    e -> {Exception.message(e), 1}
  end
end

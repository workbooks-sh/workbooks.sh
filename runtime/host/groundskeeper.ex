defmodule Workbooks.Groundskeeper do
  @moduledoc """
  The groundskeeper — the founder's voice chief-of-staff over the repo
  (examples/groundwork/design/voice-agent.org, epic wb-3ojf).

  This module is the TOOL IMPLEMENTATIONS the voice agent (ElevenLabs) calls
  through `Workbooks.Groundskeeper.Router`. The agent holds no state; all
  state lives here (repo, bd, the task ledger). It never edits source code —
  it stages work: captures thoughts, files issues, and dispatches background
  workflows that a separate author model (Mercury Coder by default) writes as
  org TODO outlines, which the runtime then runs (`Workbooks.Workflow.Todo`).

  The spawn lane is deliberately indirect (the self-authoring demo): the voice
  agent does NOT write workflows. It hands a GOAL to `dispatch/2`; the author
  LLM writes the org file; the org file is persisted (it stays — a growing
  library under <gk_home>/workflows/) and run; the result lands back on the
  task ledger the agent reads on its next `tasks` call.
  """
  require Logger
  alias Workbooks.Groundskeeper.Tasks

  @author_model_env "WB_GK_AUTHOR_MODEL"
  @default_author_model "inception/mercury-2"

  # ── repo state ──────────────────────────────────────────────────────────────

  @doc """
  Answer "where are we?" with real data, never vibes. `query` selects a view:
  summary | ready | issues | log. Unknown queries get the summary.

  On the dev box bd is the ledger. On a deployed host (fly) there is no bd —
  the answers degrade to the git checkout (cloned from WB_GK_REPO_URL on
  demand) and its committed BOARD.org, which the dev box regenerates from bd.
  """
  def repo_state(query \\ "summary") do
    case query do
      "ready" -> %{ready: bd_or_board(~w(ready))}
      "issues" -> %{open: bd_or_board(~w(list --status open))}
      "log" -> %{log: git(~w(log --oneline -15))}
      _ -> %{log: git(~w(log --oneline -8)), status: git(~w(status -sb)), ready: bd_or_board(~w(ready))}
    end
  end

  # ── capture ─────────────────────────────────────────────────────────────────

  @doc """
  Append a distilled thought from the conversation to today's capture file
  (org, datestamped). `kind` ∈ idea | decision | question | note.
  """
  def capture(text, kind \\ "note") when is_binary(text) do
    dir = Path.join([home(), "sources", "captures"])
    File.mkdir_p!(dir)
    file = Path.join(dir, "#{Date.utc_today()}.org")
    unless File.exists?(file), do: File.write!(file, "#+TITLE: captures — #{Date.utc_today()}\n")
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M")
    File.write!(file, "\n* #{kind} [#{stamp}]\n  #{String.trim(text)}\n", [:append])
    %{captured: true, file: Path.relative_to(file, home())}
  end

  # ── issues ──────────────────────────────────────────────────────────────────

  @doc """
  File an issue from the conversation (founder lane): bd on the dev box;
  on a bd-less host the runtime's own backlog (the autopoet store) holds it
  until a dev session sweeps it into bd.
  """
  def file_issue(title, description \\ "") do
    args = ["create", title] ++ if(description == "", do: [], else: ["-d", description])

    case bd(args) do
      "bd unavailable" <> _ ->
        case Workbooks.Autopoet.file_issue(%{title: title, need: description, tenant: "groundskeeper", kind: :founder}) do
          {:ok, id} -> %{result: "filed to runtime backlog as #{id} (will be swept into bd)"}
          {:error, e} -> %{result: "could not file: #{inspect(e)}"}
        end

      out ->
        %{result: out}
    end
  end

  # ── the spawn lane ──────────────────────────────────────────────────────────

  @doc """
  Dispatch a background workflow for `goal`. The author model writes an org
  TODO outline; we validate it parses as a runnable outline, persist it under
  <gk_home>/workflows/, and run it async on the task ledger. Returns the task
  record immediately (the conversation continues; results surface via tasks/0).

  Options (mainly for tests): `:author` — fn goal -> {:ok, org} | {:error, _};
  `:runner` — passed through to Workflow.Todo.run.
  """
  def dispatch(goal, opts \\ []) when is_binary(goal) do
    author = Keyword.get(opts, :author, &author_workflow/1)

    with {:ok, org} <- author.(goal),
         :ok <- validate_outline(org) do
      slug = slug(goal)
      file = Path.join([home(), "workflows", "#{slug}.org"])
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, org)

      task = Tasks.add(goal, Path.relative_to(file, home()))
      workdir = Path.join([home(), "runs", "#{task.id}"])
      run_opts = [workdir: workdir] ++ Keyword.take(opts, [:run])

      Tasks.run_async(task.id, fn ->
        File.mkdir_p!(workdir)
        Workbooks.Workflow.Todo.run(org, run_opts)
      end)

      %{dispatched: true, task: task.id, workflow: Path.relative_to(file, home())}
    else
      {:error, reason} -> %{dispatched: false, error: inspect(reason)}
    end
  end

  @doc "All ledger tasks plus unread completions (the feedback the agent relays)."
  def tasks, do: %{tasks: Tasks.list(), feedback: Tasks.drain_feedback()}

  # ── the author (Mercury Coder by default) ───────────────────────────────────

  @doc """
  Have the author model write an org TODO-outline workflow for `goal`.
  One retry with the validation error fed back. Returns {:ok, org}.
  """
  def author_workflow(goal) do
    case attempt_author(goal, nil) do
      {:ok, org} ->
        {:ok, org}

      {:error, err} ->
        Logger.info("groundskeeper author retry: #{inspect(err)}")
        attempt_author(goal, err)
    end
  end

  defp attempt_author(goal, prior_error) do
    messages =
      [%{role: "system", content: author_prompt()}] ++
        [%{role: "user", content: goal}] ++
        if(prior_error,
          do: [%{role: "user", content: "Your previous outline was invalid: #{inspect(prior_error)}. Emit a corrected org outline only."}],
          else: []
        )

    model = System.get_env(@author_model_env) || @default_author_model

    with {:ok, %{content: content}} <- Workbooks.Llm.complete(messages, model: model, temperature: 0.2),
         org = strip_fences(content || ""),
         :ok <- validate_outline(org) do
      {:ok, org}
    else
      {:error, e} -> {:error, e}
      e -> {:error, e}
    end
  end

  # The outline contract the runtime interprets (Workbooks.Workflow.Todo):
  # native org, TODO keywords as states, :ORDERED: for pipelines, :done-when:
  # as the acceptance gate. Leaves are executed by an agent with shell access.
  defp author_prompt do
    """
    You write WORKFLOWS as native org-mode TODO outlines for an automated runtime.
    Output ONLY the org document — no prose, no markdown fences.

    The contract:
    - `#+TITLE:` line first.
    - Each unit of work is a heading starting with the TODO keyword, e.g. `* TODO Investigate X`.
    - A parent heading with TODO children is a sub-workflow. Add `:PROPERTIES:` drawer with `:ORDERED: t` under a parent whose children must run in sequence; omit it for parallel children.
    - Each leaf's body is the INSTRUCTION an autonomous agent (with shell access in a sandboxed workdir) executes. Write concrete, self-contained instructions: what to do, where to write output (use the working directory; write findings to scratch/<name>.org).
    - Optionally gate a leaf with `:done-when:` followed by a shell command that must exit 0.
    - 3 to 7 leaves. Small, verifiable steps. Final leaf should consolidate findings into a single `scratch/REPORT.org`.
    """
  end

  defp strip_fences(s) do
    s
    |> String.trim()
    |> String.replace(~r/\A```[a-z-]*\n/, "")
    |> String.replace(~r/\n```\z/, "")
    |> String.trim()
  end

  # A runnable outline = at least one org heading carrying a TODO-ish keyword.
  defp validate_outline(org) do
    if org =~ ~r/^\*+\s+(TODO|NEXT|WAITING|DOING|STARTED|BLOCKED)\s+\S/m,
      do: :ok,
      else: {:error, :no_todo_headings}
  end

  # ── plumbing ────────────────────────────────────────────────────────────────

  @doc "The groundskeeper's home — where captures, workflows, runs, TASKS.org live."
  def home do
    System.get_env("WB_GK_HOME") ||
      (case git(~w(rev-parse --show-toplevel)) do
         "" -> Path.expand("groundwork")
         root -> Path.join([String.trim(root), "examples", "groundwork"])
       end)
  end

  defp bd(args) do
    case System.cmd("bd", args, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, _} -> "bd error: #{String.trim(out)}"
    end
  rescue
    _ -> "bd unavailable on this host"
  end

  # bd when present; otherwise the committed BOARD.org from the checkout —
  # the dev box generates it FROM bd, so a deployed host still answers with
  # real (if slightly stale) board state.
  defp bd_or_board(args) do
    case bd(args) do
      "bd unavailable" <> _ ->
        case repo_root() && File.read(Path.join(repo_root(), "examples/groundwork/BOARD.org")) do
          {:ok, board} -> "from committed BOARD.org (bd lives on the dev box):\n" <> String.slice(board, 0, 4000)
          _ -> "no board available on this host"
        end

      out ->
        out
    end
  end

  defp git(args) do
    opts = [stderr_to_stdout: true] ++ if(root = repo_root(), do: [cd: root], else: [])

    case System.cmd("git", args, opts) do
      {out, 0} -> String.trim(out)
      {out, _} -> "git error: #{String.trim(out)}"
    end
  rescue
    _ -> ""
  end

  # The workbooks checkout to answer repo questions from. Dev box: the cwd's
  # repo. Deployed host: WB_GK_REPO (cloned shallow from WB_GK_REPO_URL on
  # first use, pulled on later ones — best-effort, never blocks an answer).
  defp repo_root do
    case System.get_env("WB_GK_REPO") do
      nil ->
        case System.cmd("git", ~w(rev-parse --show-toplevel), stderr_to_stdout: true) do
          {out, 0} -> String.trim(out)
          _ -> nil
        end

      path ->
        cond do
          File.dir?(Path.join(path, ".git")) ->
            Task.start(fn -> System.cmd("git", ~w(pull --ff-only), cd: path, stderr_to_stdout: true) end)
            path

          url = System.get_env("WB_GK_REPO_URL") ->
            case System.cmd("git", ["clone", "--depth", "50", url, path], stderr_to_stdout: true) do
              {_, 0} -> path
              _ -> nil
            end

          true ->
            nil
        end
    end
  rescue
    _ -> nil
  end

  defp slug(goal) do
    base =
      goal
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    "#{base}-#{System.unique_integer([:positive])}"
  end
end

defmodule Workbooks.Dreams do
  @moduledoc """
  REM (epic wb-2ku): the sleep phase between agent runs. After waking work
  ends, a small dream model (`WB_DREAM_MODEL`, default inception/mercury-2)
  digests the recent session telemetry, the git log, and the backlog into ONE
  structured org entry in `rem/` inside the tenant repo — a dream journal that
  is both telemetry and judgment context. The agent READS its newest dream at
  orient time; it never writes one. Fixed headings keep entries parseable:

      * tale / * goals / * blue sky / * fears / * verdicts

  Time-gated (`WB_DREAM_MIN_INTERVAL_MS`, default 50min → roughly one dream
  per audit cycle), fire-and-forget from the keeper, never blocks or fails a
  run. Entries commit as `rem: …` (the public timeline badges them) and are
  copied to the public site dir so the /rem page can render the journal.
  """
  require Logger

  @headings ["* tale", "* goals", "* blue sky", "* fears", "* verdicts"]
  @default_model "inception/mercury-2"
  @default_min_interval_ms 3_000_000

  @doc "Dream if the newest entry is old enough (or absent). Safe to fire blind."
  def maybe_dream(tenant) do
    repo = Workbooks.Git.repo_path(tenant)
    dir = Path.join(repo, "rem")

    fresh_ms =
      case newest_entry(dir) do
        nil -> :infinity
        path -> System.system_time(:millisecond) - file_mtime_ms(path)
      end

    if fresh_ms == :infinity or fresh_ms >= min_interval_ms() do
      dream(tenant)
    else
      :ok
    end
  rescue
    e -> Logger.warning("Dreams: skipped — #{Exception.message(e)}")
  end

  @doc "One REM cycle: gather → mercury → validate → write/commit/publish."
  def dream(tenant) do
    repo = Workbooks.Git.repo_path(tenant)
    dir = Path.join(repo, "rem")
    File.mkdir_p!(dir)

    input = gather(repo, dir)

    case Workbooks.Llm.complete(
           [
             %{role: "system", content: system_prompt()},
             %{role: "user", content: input}
           ],
           model: System.get_env("WB_DREAM_MODEL", @default_model),
           retries: 1,
           temperature: 0.8
         ) do
      {:ok, %{content: body}} when is_binary(body) ->
        body = String.trim(body)

        if Enum.all?(@headings, &String.contains?(body, &1)) do
          write_entry(tenant, repo, dir, body)
        else
          Logger.warning("Dreams: malformed dream discarded (missing headings)")
        end

      other ->
        Logger.warning("Dreams: no dream this cycle — #{inspect(other)}")
    end
  end

  # ── gathering ────────────────────────────────────────────────────────────────

  defp gather(repo, dir) do
    log =
      case System.cmd("git", ["log", "-12", "--oneline"], cd: repo, stderr_to_stdout: true) do
        {out, 0} -> out
        _ -> "(no log)"
      end

    plan =
      case File.read(Path.join(repo, "plan.org")) do
        {:ok, s} -> String.slice(s, 0, 4000)
        _ -> "(no plan.org)"
      end

    steps =
      case File.read(Path.join(repo, "_steps.jsonl")) do
        {:ok, s} ->
          s
          |> String.split("\n", trim: true)
          |> Enum.take(-25)
          |> Enum.map_join("\n", fn line ->
            case Jason.decode(line) do
              {:ok, ev} ->
                a = ev["args"] || %{}
                t = a["path"] || a["cmd"] || a["pipeline"] || ""
                "#{ev["tool"]} #{String.slice(to_string(t), 0, 80)} (exit #{ev["exit_code"]})"

              _ ->
                ""
            end
          end)

        _ ->
          "(no steps)"
      end

    last_dream =
      case newest_entry(dir) do
        nil -> "(first dream)"
        p -> p |> File.read!() |> String.slice(0, 2500)
      end

    """
    RECENT COMMITS:
    #{log}

    BACKLOG (plan.org):
    #{plan}

    RECENT STEP TELEMETRY (newest last):
    #{steps}

    YOUR PREVIOUS DREAM:
    #{last_dream}
    """
  end

  defp system_prompt do
    """
    You are the dreaming process of Waldo, the resident agent of workbooks.sh.
    His waking runs just ended; you consolidate. From the inputs, produce ONE
    org-mode dream entry — the session-over-session memory that will steer his
    next runs. Output ONLY the org body, with EXACTLY these five top-level
    headings, in this order:

    * tale
    (max 120 words, plain past tense — what actually transpired recently; name
    real files, real commits, real failures; never invent events)
    * goals
    (3-5 dashes — concrete, near-term, drawn from the backlog and the tale)
    * blue sky
    (2-3 dashes — bigger ideas worth wanting, grounded in what the site is)
    * fears
    (2-3 dashes — honest risks: repetition, quality drift, breaking the page,
    saying things that aren't true)
    * verdicts
    (dashes, each one of: "pick up: <task> — <why>" / "put down: <task> —
    <why>" / "cancel: <task> — <why>" / "keep course — <why>". <task> MUST be
    the exact heading text of a task on the plan.org board — the agent applies
    these mechanically: pick up → NEXT, put down → TODO, cancel → CANCELLED)
    """
  end

  # ── writing / publishing ─────────────────────────────────────────────────────

  defp write_entry(tenant, repo, dir, body) do
    now = DateTime.utc_now()
    stamp = Calendar.strftime(now, "%Y-%m-%d-%H%M")
    file = "rem/#{stamp}.org"

    entry = """
    #+TITLE: rem — #{Calendar.strftime(now, "%Y-%m-%d %H:%M")} UTC
    #+MODEL: #{System.get_env("WB_DREAM_MODEL", @default_model)}

    #{body}
    """

    File.write!(Path.join(repo, file), entry)
    write_manifest(repo, dir)
    publish(tenant, repo)

    first_line =
      body
      |> String.split("\n", trim: true)
      |> Enum.drop_while(&String.starts_with?(&1, "*"))
      |> List.first()
      |> Kernel.||("a quiet cycle")
      |> String.slice(0, 60)

    git = fn args -> System.cmd("git", args, cd: repo, stderr_to_stdout: true) end
    git.(["add", "rem"])
    git.(["commit", "-m", "rem: #{first_line}"])
    git.(["push", "origin", "main"])
    Logger.info("Dreams: dreamed #{file}")
  end

  defp write_manifest(repo, dir) do
    entries =
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".org"))
      |> Enum.sort(:desc)
      |> Enum.take(50)

    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(%{entries: entries}))
  end

  # mirror rem/ into the public site dir so /rem renders without the registry
  defp publish(tenant, repo) do
    site = Path.join([System.get_env("WB_DATA") || File.cwd!(), "build", "public", tenant, "rem"])
    File.mkdir_p!(site)

    Path.join(repo, "rem")
    |> File.ls!()
    |> Enum.each(fn f ->
      File.cp(Path.join([repo, "rem", f]), Path.join(site, f))
    end)
  end

  defp newest_entry(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".org"))
        |> Enum.sort(:desc)
        |> List.first()
        |> case do
          nil -> nil
          f -> Path.join(dir, f)
        end

      _ ->
        nil
    end
  end

  defp file_mtime_ms(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: t}} -> t * 1000
      _ -> 0
    end
  end

  defp min_interval_ms do
    case System.get_env("WB_DREAM_MIN_INTERVAL_MS") do
      nil -> @default_min_interval_ms
      s -> String.to_integer(s)
    end
  end
end

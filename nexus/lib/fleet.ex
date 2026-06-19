defmodule Nexus.Fleet do
  @moduledoc """
  A coordinated fleet of real agents on one nexus — a foundational extension of the agent
  architecture (multi-agent work is something most agents will need, not a one-off). A coordinator
  decomposes a task into focused sub-tasks, then runs one real `Nexus.Agent` per sub-task; every
  agent streams its ACTUAL activity (thinking, the queries it searches, the pages it reads, its
  finding) into one unified fleet event stream. Budget-capped, concurrent, genuinely agentic.

  `run(task, opts)` blocks until the fleet drains, streaming to `opts[:on_event]`:

    * `%{type: "fleet", task, max}`
    * `%{type: "spawn", id, query}`                       — a real agent started
    * `%{type: "state", id, status, action, url}`        — the agent did something live
    * `%{type: "done", id, finding}`                      — an agent finished with a result
    * `%{type: "fleet_done", spawned}`

  `status` ∈ `searching | reading | thinking | done`, derived from the agent's real tool calls and
  model turns (see `Nexus.Agent`'s `:on_event`). Opts: `:max` (agents, default 12), `:agent` (the
  worker system prompt), `:model`, `:provider`, `:timeout_ms`.
  """

  @default_model "google/gemma-4-26b-a4b-it"
  @default_provider %{order: ["Cloudflare"]}
  @default_timeout 150_000

  @default_agent """
  You are a focused web research agent. Investigate the question by USING THE WEB:
    - `search <query>` to find sources (numbered title/url/snippet),
    - `scrape <url>` to read the most relevant ones.
  Do 2-4 rounds: search, read a source or two, refine, search again if needed. Think briefly before
  each step. When you have enough, reply with a 2-3 sentence finding citing key facts + the URLs.
  """

  @doc "Run a fleet for `task`, up to `:max` real agents, streaming live activity to `:on_event`."
  def run(task, opts \\ []) do
    emit = Keyword.get(opts, :on_event, fn _ -> :ok end)
    max = (opts[:max] || 12) |> max(1) |> min(64)
    model = opts[:model] || @default_model
    provider = opts[:provider] || @default_provider
    sys = opts[:agent] || @default_agent
    timeout = opts[:timeout_ms] || @default_timeout

    rounds = (opts[:rounds] || 3) |> max(1) |> min(6)
    emit.(%{type: "fleet", task: task, max: max})

    ctx = %{sys: sys, model: model, provider: provider, timeout: timeout, per_round: max, emit: emit}

    # The orchestration loop: dispatch a round of agents, then the orchestrator reads their reports,
    # digests them, and decides whether to dig deeper (follow-up questions targeting gaps) or stop.
    questions = plan(task, max, model, provider)
    {findings, _idx} = rounds_loop(task, questions, 1, rounds, 0, [], ctx)

    emit.(%{type: "synth", action: "compiling final report…"})
    report = synthesize(task, findings, model, provider)
    emit.(%{type: "report", content: report})

    emit.(%{type: "fleet_done", spawned: length(findings)})
    %{task: task, report: report, findings: findings}
  end

  # One round: announce → dispatch agents → (unless the cap) let the orchestrator digest + decide.
  defp rounds_loop(task, questions, round, max_rounds, idx, acc, ctx) do
    emit = ctx.emit
    emit.(%{type: "round", n: round, dispatching: length(questions)})

    {findings, idx2} = dispatch(questions, idx, ctx)
    acc2 = acc ++ findings

    if round >= max_rounds do
      {acc2, idx2}
    else
      case digest(task, acc2, round, max_rounds, ctx) do
        %{continue: true, questions: [_ | _] = qs} = d ->
          emit.(%{type: "digest", note: d.note, continue: true})
          rounds_loop(task, Enum.take(qs, ctx.per_round), round + 1, max_rounds, idx2, acc2, ctx)

        d ->
          emit.(%{type: "digest", note: d.note, continue: false})
          {acc2, idx2}
      end
    end
  end

  # Dispatch one round of agents concurrently (ids continue from idx → unique across rounds).
  defp dispatch(questions, idx, ctx) do
    findings =
      questions
      |> Enum.with_index()
      |> Enum.map(fn {q, i} ->
        id = "a#{idx + i + 1}"
        Task.async(fn -> worker(id, q, ctx.sys, ctx.model, ctx.provider, ctx.timeout, ctx.emit) end)
      end)
      |> Task.await_many(:infinity)

    {findings, idx + length(questions)}
  end

  # The orchestrator reads every finding so far and decides: dig deeper (new gap questions) or stop.
  defp digest(task, findings, round, max_rounds, ctx) do
    notes =
      findings
      |> Enum.reject(&(&1.finding in [nil, "", "error"]))
      |> Enum.map_join("\n", fn f -> "- #{f.subtask}: #{f.finding}" end)

    prompt =
      "You are the lead orchestrator researching: #{task}\n\n" <>
        "Your team has gathered these findings (round #{round} of up to #{max_rounds}):\n\n#{notes}\n\n" <>
        "Read them and decide: is coverage sufficient to write a thorough report, or are there " <>
        "important GAPS worth another round?\nReply EXACTLY: first line `CONTINUE` or `DONE`. " <>
        "If CONTINUE, each following line is ONE new focused sub-question targeting a gap " <>
        "(up to #{ctx.per_round}). If DONE, a one-line reason."

    case Nexus.Llm.complete([%{role: "user", content: prompt}], model: ctx.model, provider: ctx.provider, max_tokens: 500) do
      {:ok, %{content: c}} when is_binary(c) -> parse_decision(c)
      _ -> %{continue: false, note: "Coverage looks sufficient — compiling the report.", questions: []}
    end
  end

  defp parse_decision(content) do
    lines = content |> String.split("\n") |> Enum.map(&debullet/1) |> Enum.reject(&(&1 == ""))

    case lines do
      [head | rest] ->
        cond do
          String.contains?(String.upcase(head), "CONTINUE") and rest != [] ->
            %{continue: true, questions: rest, note: "Read the reports — found gaps worth a deeper round."}

          String.contains?(String.upcase(head), "DONE") ->
            %{continue: false, note: blank_to(Enum.join(rest, " "), "Coverage is sufficient — compiling the report."), questions: []}

          true ->
            %{continue: false, note: "Coverage looks sufficient — compiling the report.", questions: []}
        end

      _ ->
        %{continue: false, note: "Coverage looks sufficient — compiling the report.", questions: []}
    end
  end

  defp debullet(line), do: line |> String.replace(~r/^[\s\-*\d.\)]+/, "") |> clean(200)
  defp blank_to("", d), do: d
  defp blank_to(s, _), do: s

  # Combine the fleet's findings into a single cited report.
  defp synthesize(task, findings, model, provider) do
    notes =
      findings
      |> Enum.reject(&(&1.finding in [nil, "", "error"]))
      |> Enum.map_join("\n\n", fn f -> "### #{f.subtask}\n#{f.finding}" end)

    if String.trim(notes) == "" do
      "No findings were gathered."
    else
      prompt =
        "You are the lead researcher writing a DEEP RESEARCH REPORT on:\n#{task}\n\n" <>
          "Below are the findings your team of agents gathered over several rounds. Synthesize them " <>
          "into a thorough, well-structured report in markdown with:\n" <>
          "1. A `#` title.\n" <>
          "2. A short **Executive summary** (2-4 sentences answering the question directly).\n" <>
          "3. Several `##` thematic sections covering the substance, with concrete facts, numbers, " <>
          "tradeoffs, and inline source links where the findings cite URLs.\n" <>
          "4. A `## Key takeaways` bullet list.\n" <>
          "5. A `## Open questions` list of what remains uncertain or unexplored.\n" <>
          "Merge overlap, resolve contradictions, and be specific. Do not invent sources.\n\n" <>
          "## Agent findings\n#{notes}"

      case Nexus.Llm.complete([%{role: "user", content: prompt}], model: model, provider: provider, max_tokens: 3000) do
        {:ok, %{content: c}} when is_binary(c) and c != "" -> c
        _ -> notes
      end
    end
  end

  # Coordinator: one LLM call decomposes the task into distinct, researchable sub-tasks.
  defp plan(task, max, model, provider) do
    n = min(max, 16)

    prompt =
      "Break this task into #{n} DISTINCT, focused sub-questions a team would each investigate. " <>
        "Return ONLY the sub-questions, one per line, no numbering or extra text.\n\nTask: #{task}"

    case Nexus.Llm.complete([%{role: "user", content: prompt}], model: model, provider: provider, max_tokens: 400) do
      {:ok, %{content: c}} when is_binary(c) and c != "" ->
        c |> String.split("\n") |> Enum.map(&clean/1) |> Enum.reject(&(&1 == "")) |> Enum.take(max)

      _ ->
        []
    end
    |> case do
      [] -> [task]
      list -> list
    end
  end

  # One real agent. Streams its live activity through the agent's :on_event hook. Returns its finding.
  defp worker(id, subtask, sys, model, provider, timeout, emit) do
    emit.(%{type: "spawn", id: id, query: clean(subtask)})
    emit.(%{type: "state", id: id, status: "thinking", action: "planning research…"})

    on_event = fn ev -> Enum.each(List.wrap(translate(id, ev)), emit) end

    finding =
      case Nexus.Agent.run(
             task: subtask,
             system: sys,
             model: model,
             provider: provider,
             on_event: on_event,
             timeout_ms: timeout
           ) do
        {:ok, answer} when is_binary(answer) and answer != "" -> clean(answer, 600)
        _ -> ""
      end

    emit.(%{type: "done", id: id, finding: finding})
    %{id: id, subtask: subtask, finding: finding}
  rescue
    _ ->
      emit.(%{type: "done", id: id, finding: "error"})
      %{id: id, subtask: subtask, finding: ""}
  end

  # Map a real agent event → a fleet state event.
  defp translate(id, {:tool, cmd}) do
    {verb, rest} = split(cmd)

    cond do
      verb == "search" ->
        %{type: "state", id: id, status: "searching", action: clean(rest)}

      verb in ~w(scrape render navigate screenshot) ->
        url = rest |> String.split() |> Enum.find(&String.starts_with?(&1, "http")) || rest
        %{type: "state", id: id, status: "reading", action: clean(url), url: clean(url)}

      true ->
        %{type: "state", id: id, status: "thinking", action: clean(cmd)}
    end
  end

  defp translate(id, {:think, content}),
    do: %{type: "state", id: id, status: "thinking", action: clean(content)}

  defp translate(id, {:answer, content}),
    do: %{type: "state", id: id, status: "done", action: clean(content, 300)}

  # A scrape/read tool RESULT → a page preview the user can see in the agent's thread.
  defp translate(id, {:result, cmd, output}) do
    {verb, rest} = split(cmd)

    if verb in ~w(scrape render navigate) and is_binary(output) do
      url = rest |> String.split() |> Enum.find(&String.starts_with?(&1, "http")) || rest
      %{type: "page", id: id, url: clean(url), preview: preview(output)}
    else
      nil
    end
  end

  defp translate(_id, _other), do: nil

  # A page preview: first lines of the scraped markdown, trimmed for the thread.
  defp preview(output) do
    output
    |> String.replace(~r/\n{2,}/, "\n")
    |> String.slice(0, 360)
    |> String.trim()
  end

  defp split(cmd) do
    case String.split(String.trim(cmd), ~r/\s+/, parts: 2) do
      [v, rest] -> {v, rest}
      [v] -> {v, ""}
      _ -> {"", ""}
    end
  end

  defp clean(s, len \\ 140)

  defp clean(s, len) when is_binary(s) do
    s
    |> String.replace(~r/\.css-[^{]*\{[^}]*\}/, "")
    |> String.replace(~r/\{[^}]*\}/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, len)
  end

  defp clean(_, _), do: ""
end

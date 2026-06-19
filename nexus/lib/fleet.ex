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

    emit.(%{type: "fleet", task: task, max: max})

    subtasks = plan(task, max, model, provider)

    subtasks
    |> Enum.with_index(1)
    |> Enum.map(fn {st, i} ->
      Task.async(fn -> worker("a#{i}", st, sys, model, provider, timeout, emit) end)
    end)
    |> Task.await_many(:infinity)

    emit.(%{type: "fleet_done", spawned: length(subtasks)})
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

  # One real agent. Streams its live activity through the agent's :on_event hook.
  defp worker(id, subtask, sys, model, provider, timeout, emit) do
    emit.(%{type: "spawn", id: id, query: clean(subtask)})
    emit.(%{type: "state", id: id, status: "thinking", action: "planning research…"})

    on_event = fn ev -> emit.(translate(id, ev)) end

    result =
      Nexus.Agent.run(
        task: subtask,
        system: sys,
        model: model,
        provider: provider,
        on_event: on_event,
        timeout_ms: timeout
      )

    case result do
      {:ok, answer} when is_binary(answer) and answer != "" ->
        emit.(%{type: "done", id: id, finding: clean(answer)})

      _ ->
        emit.(%{type: "done", id: id, finding: ""})
    end
  rescue
    _ -> emit.(%{type: "done", id: id, finding: "error"})
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
    do: %{type: "state", id: id, status: "done", action: clean(content)}

  defp split(cmd) do
    case String.split(String.trim(cmd), ~r/\s+/, parts: 2) do
      [v, rest] -> {v, rest}
      [v] -> {v, ""}
      _ -> {"", ""}
    end
  end

  defp clean(s) when is_binary(s) do
    s
    |> String.replace(~r/\.css-[^{]*\{[^}]*\}/, "")
    |> String.replace(~r/\{[^}]*\}/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 140)
  end

  defp clean(_), do: ""
end

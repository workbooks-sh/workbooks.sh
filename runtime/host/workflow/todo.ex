defmodule Workbooks.Workflow.Todo do
  @moduledoc """
  Run a NATIVE org TODO outline as a workflow — no custom tags, nothing an agent
  has to learn. The outline IS the state machine:

    * TODO keywords = task states (`TODO`/`NEXT`/... → `DONE`/`CANCELLED`)
    * heading nesting = sub-workflows (composite) vs units of work (leaf)
    * `:ORDERED: t` on a parent = its children run in sequence (a pipeline);
      its ABSENCE = the children are independent → run in parallel
    * `:BLOCKER:` = an explicit edge (wait for that task id)

  A leaf TODO is executed by an agent (its heading + body is the task). A task
  only reaches DONE when its VALIDATION passes — "unit tests for org mode":
  a `:done-when:` shell command, or a `#+begin_src sh :check` block in the body.
  No check → the agent's own completion stands. Already-DONE tasks are skipped,
  so a run is resumable. Org owns the spec; this just interprets + runs it.

  Self-contained: parses org itself (no kernel/WASM dependency). Leaf execution
  is pluggable via `opts[:run]` (a `fn task -> {:ok, output} | binary` ) so it's
  testable without an LLM; the default runs `Workbooks.Agent`.
  """

  @done_states ~w(DONE CANCELLED CANCELED)
  @default_keywords ~w(TODO NEXT WAITING DOING STARTED BLOCKED) ++ @done_states

  @doc "Run an org TODO outline. Returns %{tasks: [%{id, state, output, ...}]}."
  def run(org, opts \\ []) when is_binary(org) do
    kws = keywords(org)
    tasks = parse(org, kws)
    workdir = Keyword.get(opts, :workdir, ".")
    runner = Keyword.get(opts, :run, fn t -> default_run(t, workdir) end)

    roots = children_of(tasks, nil)
    {results, _} = run_set(roots, tasks, false, %{}, runner, workdir)
    %{tasks: Map.values(results) |> Enum.sort_by(& &1.idx)}
  end

  # ── execution ────────────────────────────────────────────────────────────────
  # Run a set of sibling tasks. `ordered` → sequential; else parallel.
  defp run_set(set, all, ordered, results, runner, workdir) do
    if ordered do
      Enum.reduce(set, {results, MapSet.new()}, fn t, {res, done} ->
        {res2, _} = run_task(t, all, res, runner, workdir)
        {res2, MapSet.put(done, t.id)}
      end)
    else
      set
      |> Task.async_stream(
        fn t -> {t.id, run_task(t, all, results, runner, workdir) |> elem(0)} end,
        timeout: 1_800_000,
        max_concurrency: 8
      )
      |> Enum.reduce({results, MapSet.new()}, fn {:ok, {id, res}}, {acc, done} ->
        {Map.merge(acc, res), MapSet.put(done, id)}
      end)
    end
  end

  defp run_task(task, all, results, runner, workdir) do
    cond do
      Map.has_key?(results, task.id) ->
        {results, results[task.id].state}

      task.state in @done_states ->
        {Map.put(results, task.id, record(task, "(already DONE)", "DONE")), "DONE"}

      true ->
        kids = children_of(all, task.id)

        if kids == [] do
          run_leaf(task, results, runner, workdir)
        else
          {res2, _} = run_set(kids, all, task.ordered, results, runner, workdir)
          state = if Enum.all?(kids, &(res2[&1.id] && res2[&1.id].state == "DONE")), do: "DONE", else: "PARTIAL"
          {Map.put(res2, task.id, record(task, "(composite)", state)), state}
        end
    end
  end

  defp run_leaf(task, results, runner, workdir) do
    out =
      case runner.(task) do
        {:ok, o} -> o
        {:error, e} -> "ERROR: #{inspect(e)}"
        o when is_binary(o) -> o
        o -> inspect(o)
      end

    state = if validate(task, workdir), do: "DONE", else: "FAILED"
    {Map.put(results, task.id, record(task, out, state)), state}
  end

  # DONE only if acceptance passes. :done-when: command, or a `#+begin_src sh
  # :check` block. No check → trust the agent (DONE).
  defp validate(task, workdir) do
    cond do
      cmd = task.props["DONE-WHEN"] || task.props["DONE_WHEN"] -> sh_ok(cmd, workdir)
      block = check_block(task.body) -> sh_ok(block, workdir)
      true -> true
    end
  end

  defp sh_ok(cmd, workdir) do
    {_, code} = System.cmd("sh", ["-c", cmd], cd: workdir, stderr_to_stdout: true)
    code == 0
  rescue
    _ -> false
  end

  defp record(t, out, state),
    do: %{id: t.id, idx: t.idx, title: t.title, state: state, output: String.slice(to_string(out), 0, 600)}

  defp default_run(task, workdir) do
    sys = "You are a workflow task runner. Do exactly what the task says, using your tools. Write any output files in your CURRENT working directory. Finish with done."
    Workbooks.Agent.run(sys, "#{task.title}\n\n#{task.body}", exec: true, workdir: workdir, max_steps: 60).result
  end

  # ── parse (self-contained, no WASM) ──────────────────────────────────────────
  defp keywords(org) do
    case Regex.run(~r/^#\+TODO:\s*(.+)$/m, org) do
      [_, line] -> line |> String.replace("|", " ") |> String.split() |> Enum.uniq()
      _ -> @default_keywords
    end
  end

  defp parse(org, kws) do
    lines = String.split(org, "\n")

    {tasks, _} =
      Enum.reduce(lines, {[], []}, fn line, {acc, stack} ->
        case Regex.run(~r/^(\*+)\s+(.*)$/, line) do
          [_, stars, rest] ->
            level = String.length(stars)
            {state, title} = split_state(rest, kws)
            parent = Enum.find_value(stack, fn {l, id} -> if l < level, do: id, else: nil end)
            id = slug(title)
            stack = [{level, id} | Enum.reject(stack, fn {l, _} -> l >= level end)]
            task = %{idx: length(acc), level: level, title: title, state: state, id: id, parent: parent, props: %{}, body: "", ordered: false}
            {[task | acc], stack}

          _ ->
            case acc do
              [t | rest] -> {[%{t | body: t.body <> line <> "\n"} | rest], stack}
              [] -> {acc, stack}
            end
        end
      end)

    tasks |> Enum.reverse() |> Enum.map(&finalize/1)
  end

  defp split_state(rest, kws) do
    case String.split(rest, " ", parts: 2) do
      [w, t] -> if w in kws, do: {w, String.trim(t)}, else: {nil, rest}
      [w] -> if w in kws, do: {w, ""}, else: {nil, rest}
    end
  end

  defp finalize(t) do
    # Props from the :PROPERTIES: drawer AND bare `:KEY: val` lines (an agent
    # writes either; both are honored). Drawer wins on conflict.
    props = Map.merge(bare_props(t.body), drawer_props(t.body))
    body = t.body |> strip_drawer() |> String.trim()
    %{t | props: props, body: body, ordered: props["ORDERED"] in ["t", "true", "yes"]}
  end

  defp drawer_props(body) do
    case Regex.run(~r/:PROPERTIES:\n(.*?)\n\s*:END:/s, body) do
      [_, drawer] -> scan_props(drawer)
      _ -> %{}
    end
  end

  # Bare `:key: value` lines anywhere in the body (outside src blocks).
  defp bare_props(body) do
    body |> strip_src() |> scan_props()
  end

  defp scan_props(text) do
    Regex.scan(~r/^\s*:([A-Za-z][\w-]*):[ \t]+(.+)$/m, text)
    |> Map.new(fn [_, k, v] -> {String.upcase(k), String.trim(v)} end)
  end

  defp strip_src(body), do: String.replace(body, ~r/#\+begin_src.*?#\+end_src/s, "")

  defp strip_drawer(body), do: String.replace(body, ~r/:PROPERTIES:\n.*?\n\s*:END:\n?/s, "")

  defp check_block(body) do
    case Regex.run(~r/#\+begin_src\s+\S+[^\n]*:check[^\n]*\n(.*?)\n\s*#\+end_src/si, body) do
      [_, code] -> String.trim(code)
      _ -> nil
    end
  end

  # ── tree helpers ─────────────────────────────────────────────────────────────
  defp children_of(tasks, parent_id), do: Enum.filter(tasks, &(&1.parent == parent_id))

  defp slug(title) do
    title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-") |> String.slice(0, 48)
  end
end

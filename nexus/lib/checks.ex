defmodule Nexus.Checks do
  @moduledoc """
  Self-validating workbooks — the major use case. A `.work` file authors an `agent` (a literate
  function) and a `check` that runs that agent on a task and asserts the result. `Nexus.Checks.run/1`
  executes every check in a workbook and reports pass/fail; `weave` renders the results.

  A check is a literate unit:

      check :unique_count do
        agent lines                                              # which agent unit to run
        task Count the unique lines in /work/d.txt, reply UNIQUE=<n>   # what to ask it
        seed d.txt = apple\\nbanana\\napple                       # a file to seed into the VFS
        expect UNIQUE=2                                          # a substring the answer must contain
      end

  `expect` is a substring by default, or a `/regex/`. Multiple `seed` lines seed multiple files.
  The agent referenced by `agent <name>` must be an `agent` unit somewhere in the same workbook —
  composable: agents and checks are peers in the literate file.
  """

  @doc "Parse a `check` unit node into `%{name, agent, task, expect, seed}`."
  def parse(%{kind: "check", name: name, body: body}) do
    lines = body |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    Enum.reduce(lines, %{name: name, agent: nil, task: nil, expect: nil, seed: %{}}, fn line, acc ->
      case String.split(line, " ", parts: 2) do
        ["agent", v] -> %{acc | agent: String.trim(v)}
        ["task", v] -> %{acc | task: String.trim(v)}
        ["expect", v] -> %{acc | expect: String.trim(v)}
        ["seed", v] -> %{acc | seed: put_seed(acc.seed, v)}
        _ -> acc
      end
    end)
  end

  # `seed d.txt = a\nb` → %{"d.txt" => "a\nb"} (literal \n in source → real newline).
  defp put_seed(seed, spec) do
    case String.split(spec, "=", parts: 2) do
      [file, contents] -> Map.put(seed, String.trim(file), unescape(String.trim(contents)))
      _ -> seed
    end
  end

  defp unescape(s), do: String.replace(s, "\\n", "\n")

  @doc """
  Run every check in a workbook folder. Returns `%{passed, failed, results}` where each result is
  `%{name, passed, expect, got, error}`. Runs the real agents (LLM) — call it from a tool/CLI, not
  the default test suite.
  """
  def run(root, opts \\ []) do
    units =
      (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
      |> Enum.uniq()
      |> Enum.flat_map(fn f -> f |> File.read!() |> Nexus.Literate.parse() |> Enum.filter(&(&1.type == :code)) end)

    agents = for u <- units, u.kind == "agent", into: %{}, do: {u.name, u}
    checks = for u <- units, u.kind == "check", do: parse(u)

    results = Enum.map(checks, &run_check(&1, agents, opts))

    %{
      passed: Enum.count(results, & &1.passed),
      failed: Enum.count(results, &(not &1.passed)),
      results: results
    }
  end

  @doc "Run a single parsed check against the workbook's agents → a result map."
  def run_check(%{name: name, agent: agent_name} = check, agents, opts \\ []) do
    base = %{name: name, passed: false, expect: check.expect, got: nil, error: nil}

    case agents[agent_name] do
      nil ->
        %{base | error: "no agent named #{inspect(agent_name)} in this workbook"}

      agent_node ->
        case Nexus.Agent.run_unit(agent_node, check.task, Keyword.put(opts, :seed, check.seed)) do
          {:ok, %{answer: answer}} ->
            %{base | passed: matches?(answer, check.expect), got: answer}

          {:error, reason} ->
            %{base | error: inspect(reason)}
        end
    end
  end

  @doc "Whether `answer` satisfies `expect` (a `/regex/` or a substring). Exposed for testing."
  def matches?(_answer, nil), do: true

  def matches?(answer, "/" <> _ = re_src) do
    inner = String.trim(re_src, "/")

    case Regex.compile(inner) do
      {:ok, re} -> Regex.match?(re, answer)
      _ -> String.contains?(answer, re_src)
    end
  end

  def matches?(answer, expect), do: String.contains?(answer, expect)
end

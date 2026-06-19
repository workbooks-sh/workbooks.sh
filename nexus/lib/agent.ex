defmodule Nexus.Agent do
  @moduledoc """
  The agent composition primitive — a BEAM loop over `Nexus.Llm` with **one tool: `bash`**. This is
  the model the whole project rides on: an agent is a looping brain whose only action is to run a
  command line in `bash` (`Nexus.Agent.Bash`), which executes `wasm32-wasi` kit commands in wasmtime
  against the agent's VFS (`Nexus.Agent.Vfs`). There are no discrete tools — everything is a kit (a
  wrapped CLI) run through bash. Kits are surfaced by **progressive disclosure** (`Nexus.Agent.Kits`):
  the system prompt lists kit names, the agent runs `help <kit>` for detail when it needs it.

      call the model → if it calls bash, run the command in the VFS → append the (truncated) output →
      slide the context window → loop, until the model answers without calling bash.

  Bounded by **wall-clock** (`opts[:timeout_ms]`, default 120s), not a turn cap — long-horizon by
  design. Returns `{:ok, %{answer, turns, vfs_files}} | {:error, reason}`.
  """

  alias Nexus.Agent.{Bash, Context, Kits, Vfs}

  @default_timeout 120_000

  @bash_tool %{
    type: "function",
    function: %{
      name: "bash",
      description:
        "Run a command line in the agent's sandboxed shell. Commands are wasm CLI kits run in " <>
          "wasmtime against the /work VFS. Supports pipes (|). Builtins: `kits` (list available " <>
          "kits), `help <kit>` (a kit's commands). Returns combined stdout/stderr.",
      parameters: %{
        type: "object",
        properties: %{command: %{type: "string", description: "the command line to run"}},
        required: ["command"]
      }
    }
  }

  @doc """
  Run an agent to a final answer.

      Nexus.Agent.run(
        task: "Sort the lines in /work/data.txt and tell me the unique count.",
        system: "You are a terse data assistant.",   # optional (a sensible default is provided)
        seed: %{"data.txt" => "b\\na\\nb\\n"},          # optional files seeded into the VFS
        timeout_ms: 120_000                            # optional wall-clock budget
      )
  """
  def run(opts) do
    task = Keyword.fetch!(opts, :task)
    vfs = Vfs.new()
    for {path, contents} <- Keyword.get(opts, :seed, %{}), do: Vfs.put(vfs, path, contents)

    messages = [%{role: "system", content: system_prompt(opts)}, %{role: "user", content: task}]
    deadline = now_ms() + Keyword.get(opts, :timeout_ms, @default_timeout)
    started = now_ms()

    try do
      {result, tel} = loop(messages, vfs, opts, deadline, %{turns: 0, prompt: 0, completion: 0, total: 0, tools: []})
      record_run(opts[:unit], result, tel, started)
      result
    after
      Vfs.destroy(vfs)
    end
  end

  # fold each run into the execution-reality ledger (§10), keyed by unit identity.
  defp record_run(unit, result, tel, started) do
    status =
      case result do
        {:ok, _} -> :ok
        {:error, {:timeout, _}} -> :timeout
        {:error, _} -> :error
      end

    Nexus.Telemetry.record(unit, %{
      at: started,
      turns: tel.turns,
      tokens: %{prompt: tel.prompt, completion: tel.completion, total: tel.total},
      latency_ms: now_ms() - started,
      tools: Enum.frequencies(tel.tools),
      status: status,
      error: if(status == :error, do: inspect(elem(result, 1)))
    })
  end

  # accumulate a turn's token usage + the kits it invoked into the telemetry acc.
  defp tally(tel, turn, calls) do
    u = Map.get(turn, :usage, %{})

    %{
      tel
      | turns: tel.turns + 1,
        prompt: tel.prompt + (u["prompt_tokens"] || 0),
        completion: tel.completion + (u["completion_tokens"] || 0),
        total: tel.total + (u["total_tokens"] || 0),
        tools: tel.tools ++ Enum.map(calls, &kit_of/1)
    }
  end

  # the kit a bash tool-call exercised — the first token of the command.
  defp kit_of(%{args: %{"command" => cmd}}) when is_binary(cmd) do
    cmd |> String.trim_leading() |> String.split(~r/\s+/, parts: 2) |> List.first() || "bash"
  end

  defp kit_of(_), do: "bash"

  @doc """
  Build a runnable agent def from a parsed `agent` unit node — an agent authored as a literate
  function in a `.work` file (`agent :name do <system prompt> end`). Returns `%{name, system}`.
  """
  def def_from_unit(%{kind: "agent", name: name, body: body}),
    do: %{name: name, system: String.trim(body || "")}

  @doc "Run an `agent` unit node on `task`. The unit body is the agent's system prompt."
  def run_unit(node, task, opts \\ []) do
    d = def_from_unit(node)
    run(Keyword.merge([system: d.system, task: task, unit: d.name], opts))
  end

  defp loop(messages, vfs, opts, deadline, tel) do
    emit = Keyword.get(opts, :on_event, fn _ -> :ok end)
    # Generic typed side-channel (default no-op) — feeds the SSE streaming endpoint. Additive: it
    # carries map events keyed by :type and never changes loop's return value.
    stream = Keyword.get(opts, :emit, fn _ -> :ok end)

    if now_ms() > deadline do
      stream.(%{type: "error", error: inspect({:timeout, tel.turns})})
      {{:error, {:timeout, tel.turns}}, tel}
    else
      case Nexus.Llm.complete(manage(messages, opts), Keyword.put(opts, :tools, [@bash_tool])) do
        {:ok, %{tool_calls: []} = turn} ->
          if reasoning?(turn.content), do: emit.({:answer, turn.content})
          stream.(%{type: "final", answer: turn.content})
          tel = tally(tel, turn, [])
          {{:ok, %{answer: turn.content, turns: tel.turns, vfs_files: Vfs.ls(vfs)}}, tel}

        {:ok, %{tool_calls: calls} = turn} ->
          if reasoning?(turn.content), do: emit.({:think, turn.content})
          if reasoning?(turn.content), do: stream.(%{type: "text", content: turn.content})
          stream.(%{type: "tools", count: length(calls), commands: Enum.map(calls, &command_of/1)})
          Enum.each(calls, fn c -> emit.({:tool, command_of(c)}) end)
          tel = tally(tel, turn, calls)
          assistant = %{role: "assistant", content: turn.content || "", tool_calls: raw_calls(calls)}

          results =
            Enum.map(calls, fn c ->
              r = run_bash(c, vfs)
              emit.({:result, command_of(c), r.content})
              r
            end)

          loop(messages ++ [assistant | results], vfs, opts, deadline, tel)

        {:error, reason} ->
          stream.(%{type: "error", error: inspect(reason)})
          {{:error, reason}, tel}
      end
    end
  end

  defp reasoning?(c), do: is_binary(c) and String.trim(c) != ""
  defp command_of(%{args: %{"command" => cmd}}) when is_binary(cmd), do: cmd
  defp command_of(_), do: ""

  # Context strategy: plain sliding window (default), or compaction (summarize dropped spans) when
  # `compact: true` — the solid method for long-horizon runs that must not lose early facts.
  defp manage(messages, opts) do
    if Keyword.get(opts, :compact, false) do
      Context.compact(messages, &summarize/1)
    else
      Context.window(messages)
    end
  end

  defp summarize(text) do
    case Nexus.Llm.complete([
           %{role: "system", content: "Compress the following into a terse summary that preserves all facts, decisions, and file state. Be brief."},
           %{role: "user", content: text}
         ]) do
      {:ok, %{content: c}} when is_binary(c) and c != "" -> c
      _ -> String.slice(text, 0, 2_000)
    end
  end

  defp run_bash(%{id: id, name: "bash", args: %{"command" => command}}, vfs) do
    output = vfs |> Bash.run(command) |> Context.truncate()
    %{role: "tool", tool_call_id: id, content: output}
  end

  defp run_bash(%{id: id}, _vfs),
    do: %{role: "tool", tool_call_id: id, content: "bash: malformed call (expected {command})"}

  defp raw_calls(calls) do
    Enum.map(calls, fn c ->
      %{id: c.id, type: "function", function: %{name: c.name, arguments: Jason.encode!(c.args)}}
    end)
  end

  defp system_prompt(opts) do
    Keyword.get(opts, :system, "You are a capable agent.") <>
      "\n\nYou have ONE tool: `bash`. You accomplish everything by running command lines in it. " <>
      "Commands are kits (wasm CLIs) run in a sandbox against the /work filesystem. Available kits:\n" <>
      Kits.summary() <>
      "\n\n" <> web_capability() <>
      "\n\nRun `help <kit>` to see a kit's commands before using it. When you have the answer, " <>
      "reply directly without calling bash."
  end

  # The web is a CORE capability (not a kit to discover) — every agent can read AND operate the web.
  defp web_capability do
    """
    THE WEB (core — use these in bash directly):
      search <query>      — web search → a numbered list of {title, url, snippet} to then scrape
      scrape <url>        — a page's readable text (rendered in-sandbox, CSS-aware)
      scrape --js <url>   — same, but RUN the page's JavaScript first (real DOM, for client-rendered
                            SPAs); slower. Use when a plain scrape comes back empty/shell-only.
      screenshot <url>    — render the page to a PNG in /work (add --js to run scripts first)
      navigate <url>      — open a page: shows its text + numbered LINKS and FORMS
      click <n|text>      — follow link n (or the link matching text) → the next page
      fill <name> <value> — set a form field; submit <n> — submit form n (search, login, multi-step)
    Use navigate→click/fill/submit to OPERATE a site (search, browse, fill forms), not just read it.\
    """
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end

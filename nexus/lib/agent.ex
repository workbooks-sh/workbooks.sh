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

    try do
      loop(messages, vfs, opts, deadline, 0)
    after
      Vfs.destroy(vfs)
    end
  end

  defp loop(messages, vfs, opts, deadline, turns) do
    if now_ms() > deadline do
      {:error, {:timeout, turns}}
    else
      case Nexus.Llm.complete(Context.window(messages), Keyword.put(opts, :tools, [@bash_tool])) do
        {:ok, %{tool_calls: []} = turn} ->
          {:ok, %{answer: turn.content, turns: turns + 1, vfs_files: Vfs.ls(vfs)}}

        {:ok, %{tool_calls: calls} = turn} ->
          assistant = %{role: "assistant", content: turn.content || "", tool_calls: raw_calls(calls)}
          results = Enum.map(calls, &run_bash(&1, vfs))
          loop(messages ++ [assistant | results], vfs, opts, deadline, turns + 1)

        {:error, reason} ->
          {:error, reason}
      end
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
      "\n\nRun `help <kit>` to see a kit's commands before using it. When you have the answer, " <>
      "reply directly without calling bash."
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end

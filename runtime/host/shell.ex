defmodule Workbooks.Shell do
  @moduledoc """
  A pipe shell for in-WASM commands (wb-11ck.20) — replaces the OS-forking
  `bash_runner` with sandboxed wasm. A pipeline `cmd args | cmd args | ...` runs
  each stage as a registered WASM command (CommandRegistry), piping stdout→stdin
  in memory — no OS process, no fork, just wasmtime per stage. This is the
  agent's bash-type surface: `jq '.users[].name' | grep ada | upper`.

  Stage protocol matches the command convention: a stage's `args` become the
  command's first stdin line, the piped data follows (so `jq '.x'` sends
  `.x\\n<json>`). An argless stage (e.g. `upper`) gets the piped data raw.
  Host-orchestrated pipes, wasm-sandboxed stages — the same shape as `run_dag`,
  for the interactive/command path.
  """
  alias Workbooks.CommandRegistry

  @doc """
  Run a `|`-separated pipeline over `stdin`. Returns {:ok, output} or the first
  stage error {:error, reason}. Each stage is a registered WASM command.
  """
  def run(pipeline, stdin \\ "") when is_binary(pipeline) do
    pipeline
    |> split_pipes()
    |> Enum.map(&String.trim/1)
    |> Enum.reduce({:ok, stdin}, fn
      stage, {:ok, input} -> exec(stage, input)
      _stage, err -> err
    end)
  end

  # Split on top-level `|` only — a `|` inside quotes (e.g. jq's `.items | length`)
  # stays part of its stage. Proper shell tokenization, not a naive split.
  defp split_pipes(str) do
    {parts, cur, _q} =
      Enum.reduce(String.to_charlist(str), {[], [], nil}, fn ch, {parts, cur, q} ->
        cond do
          is_nil(q) and ch in [?', ?"] -> {parts, [ch | cur], ch}
          q == ch -> {parts, [ch | cur], nil}
          is_nil(q) and ch == ?| -> {[Enum.reverse(cur) | parts], [], nil}
          true -> {parts, [ch | cur], q}
        end
      end)

    Enum.reverse([Enum.reverse(cur) | parts]) |> Enum.map(&List.to_string/1)
  end

  defp exec(stage, input) do
    case tokenize(stage) do
      [] -> {:ok, input}
      [cmd | argv] -> CommandRegistry.run(cmd, input, argv)
    end
  end

  # Split a stage into [cmd | argv], honoring single/double quotes and stripping
  # one quote layer per token: `jq '.a | b'` → ["jq", ".a | b"]; `sd a b` →
  # ["sd", "a", "b"]. The registry then applies each command's arg mode (real
  # argv for auto-wrapped CLIs; first-stdin-line for legacy jq/grep).
  defp tokenize(stage) do
    {toks, cur, started, _q} =
      stage
      |> String.to_charlist()
      |> Enum.reduce({[], [], false, nil}, fn ch, {toks, cur, started, q} ->
        cond do
          is_nil(q) and ch in [?', ?"] ->
            {toks, cur, true, ch}

          q == ch ->
            {toks, cur, started, nil}

          is_nil(q) and ch in [?\s, ?\t] ->
            if started, do: {[Enum.reverse(cur) | toks], [], false, nil}, else: {toks, cur, false, nil}

          true ->
            {toks, [ch | cur], true, q}
        end
      end)

    toks = if started, do: [Enum.reverse(cur) | toks], else: toks
    toks |> Enum.reverse() |> Enum.map(&List.to_string/1)
  end
end

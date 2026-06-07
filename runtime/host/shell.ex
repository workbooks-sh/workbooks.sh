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
    {cmd, args} =
      case String.split(stage, " ", parts: 2) do
        [c] -> {c, ""}
        [c, a] -> {c, a |> String.trim() |> unquote_arg()}
      end

    stdin = if args == "", do: input, else: args <> "\n" <> input
    CommandRegistry.run(cmd, stdin)
  end

  # Strip one layer of matching surrounding quotes (LLMs habitually quote args).
  defp unquote_arg(<<q, rest::binary>> = s) when q in [?', ?"] do
    if byte_size(rest) >= 1 and binary_part(rest, byte_size(rest) - 1, 1) == <<q>>,
      do: binary_part(rest, 0, byte_size(rest) - 1),
      else: s
  end

  defp unquote_arg(s), do: s
end

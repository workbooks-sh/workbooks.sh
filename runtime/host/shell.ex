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
  def run(pipeline, stdin \\ "", opts \\ []) when is_binary(pipeline) do
    # `opts[:dirs]` are WASI preopens (host::guest) so commands can read/write the
    # agent's files (e.g. `cat workdir/x`). Top-level `;` sequences pipelines: each
    # runs on the original stdin and their outputs concatenate (like a shell).
    # `&&`/`||` need exit codes (run path) — a follow-up. Final result is trimmed.
    dirs = Keyword.get(opts, :dirs, [])

    pipeline
    |> split_top(?;)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce({:ok, []}, fn
      pipe, {:ok, acc} ->
        case run_pipe(pipe, stdin, dirs) do
          {:ok, out} -> {:ok, [out | acc]}
          err -> err
        end

      _pipe, err ->
        err
    end)
    |> case do
      {:ok, outs} -> {:ok, outs |> Enum.reverse() |> Enum.join() |> String.trim()}
      other -> other
    end
  end

  # One `cmd | cmd | …` pipeline. Inter-stage data is byte-exact (exec passes
  # trim: false, so `wc -l` et al. see trailing newlines).
  defp run_pipe(pipe, stdin, dirs) do
    pipe
    |> split_pipes()
    |> Enum.map(&String.trim/1)
    |> Enum.reduce({:ok, stdin}, fn
      stage, {:ok, input} -> exec(stage, input, dirs)
      _stage, err -> err
    end)
  end

  # Split on a top-level separator char only — a `|`/`;` inside quotes (e.g. jq's
  # `.items | length`) stays part of its stage. Proper tokenization, not a split.
  defp split_pipes(str), do: split_top(str, ?|)

  defp split_top(str, sep) do
    {parts, cur, _q} =
      Enum.reduce(String.to_charlist(str), {[], [], nil}, fn ch, {parts, cur, q} ->
        cond do
          is_nil(q) and ch in [?', ?"] -> {parts, [ch | cur], ch}
          q == ch -> {parts, [ch | cur], nil}
          is_nil(q) and ch == sep -> {[Enum.reverse(cur) | parts], [], nil}
          true -> {parts, [ch | cur], q}
        end
      end)

    Enum.reverse([Enum.reverse(cur) | parts]) |> Enum.map(&List.to_string/1)
  end

  # Coreutils provided by the multicall `wbox` wasm — dispatched as `wbox <applet>`
  # so the shell has real echo/cat/seq/head/wc without N separate binaries (wb-9ja).
  @wbox ~w(cat echo seq head wc nl rev basename dirname tr sort uniq tail true false)

  defp exec(stage, input, dirs) do
    case tokenize(stage) do
      [] -> {:ok, input}
      [cmd | argv] when cmd in @wbox -> CommandRegistry.run("wbox", input, [cmd | argv], dirs, trim: false)
      [cmd | argv] -> CommandRegistry.run(cmd, input, argv, dirs, trim: false)
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

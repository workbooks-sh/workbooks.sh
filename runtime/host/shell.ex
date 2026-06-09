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
    # agent's files. Control operators `;` `&&` `||` sequence pipelines with
    # short-circuit on exit status; outputs concatenate. Final result is trimmed.
    dirs = Keyword.get(opts, :dirs, [])

    pipeline
    |> String.to_charlist()
    |> split_ops()
    |> eval_ops(stdin, dirs, 0, [], %{})
  end

  # Evaluate [{op, segment}] with short-circuit: `;` always runs the next, `&&`
  # only if the previous pipeline succeeded (status 0), `||` only if it failed.
  # Carries a var map: `NAME=value` segments assign (no output); `$NAME`/`${NAME}`
  # expand in subsequent segments.
  defp eval_ops([], _stdin, _dirs, _status, acc, _vars),
    do: {:ok, acc |> Enum.reverse() |> Enum.join() |> String.trim()}

  defp eval_ops([{op, seg} | rest], stdin, dirs, status, acc, vars) do
    skip? = (op == :and and status != 0) or (op == :or and status == 0)

    cond do
      seg == "" ->
        eval_ops(rest, stdin, dirs, status, acc, vars)

      skip? ->
        eval_ops(rest, stdin, dirs, status, acc, vars)

      true ->
        expanded = expand_vars(seg, vars)

        case assignment(expanded) do
          {name, val} ->
            eval_ops(rest, stdin, dirs, 0, acc, Map.put(vars, name, val))

          nil ->
            case run_pipe(expanded, stdin, dirs) do
              {:ok, out, st} -> eval_ops(rest, stdin, dirs, st, [out | acc], vars)
              {:error, _} = err -> err
            end
        end
    end
  end

  # `NAME=value` (value optionally quoted) → {name, value}; else nil.
  defp assignment(seg) do
    case Regex.run(~r/^([A-Za-z_]\w*)=(.*)$/, seg) do
      [_, name, val] -> {name, unquote_val(String.trim(val))}
      _ -> nil
    end
  end

  defp unquote_val(v) do
    cond do
      String.length(v) >= 2 and String.starts_with?(v, "\"") and String.ends_with?(v, "\"") -> String.slice(v, 1..-2//1)
      String.length(v) >= 2 and String.starts_with?(v, "'") and String.ends_with?(v, "'") -> String.slice(v, 1..-2//1)
      true -> v
    end
  end

  # Expand $NAME / ${NAME} from the var map. Unknown names are left LITERAL (not
  # blanked) so a command's own `$` survives — jq `$var`, a `$` regex, etc.
  defp expand_vars(seg, vars) when map_size(vars) == 0, do: seg

  defp expand_vars(seg, vars) do
    Regex.replace(~r/\$\{(\w+)\}|\$(\w+)/, seg, fn full, g1, g2 ->
      case Map.fetch(vars, g1 <> g2) do
        {:ok, v} -> v
        :error -> full
      end
    end)
  end

  # One `cmd | cmd | …` pipeline → {:ok, out, exit_status} | {:error, _}. The
  # pipeline's status is its last stage's; inter-stage data is byte-exact.
  defp run_pipe(pipe, stdin, dirs) do
    pipe
    |> split_pipes()
    |> Enum.map(&String.trim/1)
    |> Enum.reduce({:ok, stdin, 0}, fn
      stage, {:ok, input, _st} -> exec(stage, input, dirs)
      _stage, err -> err
    end)
  end

  # Split a command line into [{op, segment}] on top-level ; && || (quote-aware).
  # `op` is the operator PRECEDING the segment (:seq for the first / after `;`).
  # A single `|` (pipe) is left in the segment for split_pipes.
  defp split_ops(chars), do: split_ops(chars, [], [], :seq, nil)
  defp split_ops([], segs, cur, op, _q), do: Enum.reverse([{op, seg_str(cur)} | segs])

  defp split_ops([c | rest], segs, cur, op, q) do
    cond do
      is_nil(q) and c in [?', ?"] -> split_ops(rest, segs, [c | cur], op, c)
      q == c -> split_ops(rest, segs, [c | cur], op, nil)
      is_nil(q) and c == ?; -> split_ops(rest, [{op, seg_str(cur)} | segs], [], :seq, nil)
      is_nil(q) and c == ?& and match?([?& | _], rest) -> split_ops(tl(rest), [{op, seg_str(cur)} | segs], [], :and, nil)
      is_nil(q) and c == ?| and match?([?| | _], rest) -> split_ops(tl(rest), [{op, seg_str(cur)} | segs], [], :or, nil)
      true -> split_ops(rest, segs, [c | cur], op, q)
    end
  end

  defp seg_str(cur), do: cur |> Enum.reverse() |> List.to_string() |> String.trim()

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
      [] -> {:ok, input, 0}
      [cmd | argv] when cmd in @wbox -> CommandRegistry.run_status("wbox", input, [cmd | argv], dirs, trim: false)
      [cmd | argv] -> CommandRegistry.run_status(cmd, input, argv, dirs, trim: false)
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

defmodule Nexus.Agent.Bash do
  @moduledoc """
  `bash` — the agent's ONE tool. The agent does everything by running a command line here; there are
  no other tools. A command resolves to a kit's `wasm32-wasi` binary (`Nexus.Agent.Kits`) and runs in
  **wasmtime** against the agent's **VFS** (`Nexus.Agent.Vfs`, mounted at `/work`). Pipes (`|`) chain
  stdout→stdin. Two builtins for progressive disclosure: `kits` (list) and `help <kit>` (a kit's
  commands).

  The host orchestrates wasmtime (the `< stdin` redirect is host-side plumbing); the GUEST command is
  fully sandboxed — it sees only `/work` and runs as wasm, never native code. That's the security line.
  """

  # Per-command wall-clock budget for a wasm kit invocation. A hung/spinning kit (`yes`, an infinite
  # loop) must NOT hang the agent forever, nor leak a wasmtime process. Configurable via
  # `config :nexus, Nexus.Agent.Bash, cmd_timeout_ms: …`.
  @cmd_timeout_ms 30_000

  @doc "Run a command line against `vfs`. Returns combined stdout (stderr appended on error)."
  def run(vfs, line) when is_binary(line) do
    line
    |> split_pipes()
    |> Enum.reduce("", fn segment, stdin -> run_segment(vfs, segment, stdin) end)
  end

  defp cmd_timeout_ms,
    do: Application.get_env(:nexus, __MODULE__, []) |> Keyword.get(:cmd_timeout_ms, @cmd_timeout_ms)

  # Split on top-level `|` (not inside quotes).
  defp split_pipes(line) do
    line
    |> tokenize_keeping_pipes()
    |> Enum.chunk_by(&(&1 == :pipe))
    |> Enum.reject(&(&1 == [:pipe]))
    |> Enum.map(&Enum.reject(&1, fn t -> t == :pipe end))
  end

  defp run_segment(_vfs, [], stdin), do: stdin

  defp run_segment(vfs, [cmd | args], stdin) do
    case cmd do
      "kits" -> Nexus.Agent.Kits.summary()
      "help" -> Nexus.Agent.Kits.help(List.first(args) || "")
      # web access is HOST-BROKERED (wasm has no sockets) — `fetch <url>` and `scrape <url>` go
      # through Nexus.Dock.fetch (SSRF-safe: loopback/private blocked, https). curl-class.
      "fetch" -> web_fetch(List.first(args))
      "scrape" -> List.first(args) |> web_fetch() |> html_to_text()
      _ -> exec(vfs, cmd, args, stdin)
    end
  end

  defp web_fetch(nil), do: "fetch: usage: fetch <url>"
  defp web_fetch(url) do
    case Nexus.Dock.fetch(url) do
      "" -> "fetch: empty or blocked (#{url})"
      body -> body
    end
  end

  # Strip a page to readable text: drop script/style, tags → spaces, decode common entities,
  # collapse whitespace. Zero-dep (good enough for an agent to read a page).
  defp html_to_text(html) do
    html
    |> String.replace(~r{<(script|style)\b[^>]*>.*?</\1>}is, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> decode_entities()
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n\s*\n\s*/, "\n\n")
    |> String.trim()
  end

  @entities %{"&amp;" => "&", "&lt;" => "<", "&gt;" => ">", "&quot;" => "\"", "&#39;" => "'",
              "&apos;" => "'", "&nbsp;" => " "}
  defp decode_entities(s),
    do: Enum.reduce(@entities, s, fn {e, c}, acc -> String.replace(acc, e, c) end)

  defp exec(vfs, cmd, args, stdin) do
    case Nexus.Agent.Kits.resolve(cmd) do
      nil ->
        "bash: #{cmd}: command not found (try `kits` to list, `help <kit>` for usage)"

      {wasm, leading} ->
        run_wasm(vfs, wasm, leading ++ args, stdin)
    end
  end

  # Run a wasm command in wasmtime against the VFS, feeding `stdin`, capturing stdout. The host `sh`
  # only does the `< stdinfile` redirect + arg passing — the executed command is the sandboxed wasm.
  defp run_wasm(vfs, wasm, argv, stdin) do
    stdin_file = Path.join(System.tmp_dir!(), "nexus_stdin_#{System.unique_integer([:positive])}")
    File.write!(stdin_file, stdin)

    inner =
      ["wasmtime", "run", "--dir", Nexus.Agent.Vfs.mount(vfs), wasm | argv]
      |> Enum.map_join(" ", &shq/1)

    # Wrap in a shell watchdog: background the kit, start a killer that SIGKILLs it (and any wasmtime
    # children) after the budget, then `wait`. A spinning/hung kit (`yes`, an infinite loop) is reaped
    # by the OS — it can never hang the agent or leak a wasmtime process. Exit 137 = SIGKILL = timed out.
    secs = max(1, div(cmd_timeout_ms(), 1000))
    # The killer subshell must NOT inherit the pipe stdout (it would hold the port open and block
    # System.cmd until `sleep` returns). Redirect its fds to /dev/null and run it detached.
    guarded =
      "#{inner} < #{shq(stdin_file)} & cmd=$!; " <>
        "{ sleep #{secs}; kill -9 $cmd 2>/dev/null; pkill -9 -P $cmd 2>/dev/null; } >/dev/null 2>&1 & w=$!; " <>
        "wait $cmd; rc=$?; kill $w 2>/dev/null; wait $w 2>/dev/null; exit $rc"

    {out, code} = System.cmd("sh", ["-c", guarded], stderr_to_stdout: true)
    File.rm(stdin_file)

    cond do
      code == 0 -> out
      code == 137 -> out <> "\nbash: #{List.first(argv) || "command"}: killed (exceeded #{secs}s time budget)"
      true -> out <> "\n(exit #{code})"
    end
  end

  defp shq(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  # Tokenize respecting "double" and 'single' quotes; `|` outside quotes is the :pipe marker.
  defp tokenize_keeping_pipes(line), do: tok(String.graphemes(line), :ws, "", [])

  defp tok([], _state, cur, acc), do: flush(cur, acc) |> Enum.reverse()

  defp tok([c | rest], :ws, cur, acc) do
    case c do
      " " -> tok(rest, :ws, cur, acc)
      "|" -> tok(rest, :ws, "", [:pipe | flush(cur, acc)])
      "\"" -> tok(rest, :dq, cur, acc)
      "'" -> tok(rest, :sq, cur, acc)
      _ -> tok(rest, :word, cur <> c, acc)
    end
  end

  defp tok([c | rest], :word, cur, acc) do
    case c do
      " " -> tok(rest, :ws, "", flush(cur, acc))
      "|" -> tok(rest, :ws, "", [:pipe | flush(cur, acc)])
      "\"" -> tok(rest, :dq, cur, acc)
      "'" -> tok(rest, :sq, cur, acc)
      _ -> tok(rest, :word, cur <> c, acc)
    end
  end

  defp tok([c | rest], :dq, cur, acc) do
    if c == "\"", do: tok(rest, :word, cur, acc), else: tok(rest, :dq, cur <> c, acc)
  end

  defp tok([c | rest], :sq, cur, acc) do
    if c == "'", do: tok(rest, :word, cur, acc), else: tok(rest, :sq, cur <> c, acc)
  end

  defp flush("", acc), do: acc
  defp flush(word, acc), do: [word | acc]
end

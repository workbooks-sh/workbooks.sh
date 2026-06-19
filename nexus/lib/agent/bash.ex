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
      # scrape/render <url> → the page's rendered TEXT via in-wasm Blitz (CSS-aware, no JS),
      # falling back to a naive tag-strip if the renderer is unavailable.
      "scrape" -> web_render(args)
      "render" -> web_render(args)
      # in-wasm Blitz render: screenshot <url> [out.png] → a PNG in /work.
      "screenshot" -> web_screenshot(vfs, args)
      # Tier-1 computer-use: operate a site by semantic action (browser-use model).
      "navigate" -> nav_result(Nexus.Browse.Session.navigate(List.first(args) || ""))
      "links" -> format_session(Nexus.Browse.Session.current(), :links)
      "forms" -> format_session(Nexus.Browse.Session.current(), :forms)
      "click" -> nav_result(Nexus.Browse.Session.click(List.first(args) || ""))
      "fill" -> fill_result(args)
      "submit" -> nav_result(Nexus.Browse.Session.submit(submit_index(args)))
      _ -> exec(vfs, cmd, args, stdin)
    end
  end

  # `scrape [--js] <url>` — `--js` selects the greenfield engine (StarlingMonkey+linkedom runs the
  # page's JS against a real DOM before render); default is the fast CSS-only render.
  defp web_render(args) do
    {opts, rest} = take_js_flag(args, :auto)

    case List.first(rest) do
      nil -> "render: usage: render [--js] <url>"
      url ->
        case Nexus.Browse.render(url, opts) do
          {:ok, text} when is_binary(text) and text != "" -> text
          # fall back to the naive tag-strip if the in-wasm renderer is unavailable
          _ -> url |> web_fetch() |> html_to_text()
        end
    end
  end

  # Pull a `--js` flag → render opts selecting `engine` (default `:auto` — fast-first, escalate to the
  # heavy JS engine only when the fast render is thin, keep the richer result; never regress).
  defp take_js_flag(args, engine) do
    if "--js" in args, do: {[engine: engine], args -- ["--js"]}, else: {[], args}
  end

  # ── Tier-1 computer-use builtins ───────────────────────────────────────────
  defp nav_result({:ok, s}), do: format_session(s, :page)
  defp nav_result({:error, reason}), do: "browse: #{inspect(reason) |> String.slice(0, 100)}"

  defp fill_result([field | rest]) when rest != [] do
    value = Enum.join(rest, " ")
    Nexus.Browse.Session.fill(field, value)
    "fill: #{field} = #{value}"
  end

  defp fill_result(_), do: "fill: usage: fill <field-name> <value>"

  defp submit_index(args) do
    case args do
      [n | _] -> case Integer.parse(n), do: ({i, _} -> i; _ -> 1)
      _ -> 1
    end
  end

  # Render a session for the agent: the page text + numbered actionables (links/forms) to act on.
  defp format_session(s, view) do
    header = if s.url, do: "URL: #{s.url}\n", else: ""

    body =
      case view do
        :page -> String.slice(s.text, 0, 4_000) <> "\n\n" <> actionables(s)
        :links -> link_list(s.links)
        :forms -> form_list(s.forms)
      end

    header <> body
  end

  defp actionables(s) do
    "── LINKS (click <n>) ──\n" <> link_list(Enum.take(s.links, 30)) <>
      (if s.forms == [], do: "", else: "\n── FORMS (fill <name> <value>; submit <n>) ──\n" <> form_list(s.forms))
  end

  defp link_list([]), do: "(none)"
  defp link_list(links) do
    links
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {l, i} -> "#{i}. #{String.slice(l.text, 0, 70)}" end)
  end

  defp form_list([]), do: "(none)"
  defp form_list(forms) do
    forms
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {f, i} ->
      fields = f.fields |> Enum.map_join(", ", & &1.name)
      "#{i}. #{f.method} #{f.action} — fields: #{fields}"
    end)
  end

  defp web_screenshot(_vfs, []), do: "screenshot: usage: screenshot [--js] <url> [out.png]"

  defp web_screenshot(vfs, args) do
    {opts, rest} = take_js_flag(args, :jsdom)
    web_screenshot(vfs, rest, opts)
  end

  defp web_screenshot(_vfs, [], _opts), do: "screenshot: usage: screenshot [--js] <url> [out.png]"

  defp web_screenshot(vfs, [url | rest], opts) do
    out = List.first(rest) || "screenshot.png"

    case Nexus.Browse.screenshot(url, opts) do
      {:ok, png} ->
        Nexus.Agent.Vfs.put(vfs, out, png)
        "screenshot: #{url} -> /work/#{out} (#{byte_size(png)} bytes)"

      {:error, reason} ->
        "screenshot: failed (#{inspect(reason) |> String.slice(0, 80)})"
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

    {flags, exec} = Nexus.Wasm.Aot.resolve(wasm)

    inner =
      (["wasmtime", "run"] ++ flags ++ ["--dir", Nexus.Agent.Vfs.mount(vfs), exec | argv])
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

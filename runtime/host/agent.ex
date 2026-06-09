defmodule Workbooks.Agent do
  @moduledoc """
  The agent loop (the brandnana model, on the clean-room substrate). An agent is a
  BEAM loop: call the LLM → if it requests tools, run them → append results →
  loop, until the model stops calling tools or signals `done`. Long-horizon by
  construction (bounded by `max_steps`, resumable because state lives in the VFS).

  The clean-room improvement over brandnana's raw `bash`: the agent's primary tool
  is the *sandboxed in-WASM shell* (`Workbooks.Shell` over the CommandRegistry —
  coreutils + jq/grep, pipes, `; && ||`, vars, redirection, workdir files) and the
  *VFS*. No OS shell by default; the `run` escape hatch (native CLIs, exec-gated +
  Workbooks.Sandbox) is being retired as CLIs become WASM commands (wb-9ja).
  Every step is appended to an org-mode event log in the VFS (`events.org`) — the
  run is fully observable and OQL-queryable, like brandnana's events.org.
  """
  alias Workbooks.{Llm, Shell, VFS}

  # ESCAPE HATCH (deprecated): real OS bash for NATIVE CLIs not yet available as
  # WASM commands (e.g. ffmpeg, git, gh). Only granted to trusted agents
  # (opts[:exec]) and run under Workbooks.Sandbox. Prefer the `shell` tool — it is
  # fully WASM-sandboxed. To be removed once every CLI is a WASM command (wb-9ja).
  @run_tool %{type: "function", function: %{
    name: "run",
    description: "ESCAPE HATCH — only for NATIVE CLIs the `shell` tool can't run yet (e.g. ffmpeg, git, gh). For everything else use `shell` (it has cat/echo/grep/jq/sort/pipes/redirection/files). Runs a real command in your working dir; returns stdout+stderr. e.g. cmd=\"ffmpeg -i in.mp4 out.wav\".",
    parameters: %{type: "object", properties: %{cmd: %{type: "string"}}, required: ["cmd"]}
  }}

  @base_tools [
    %{type: "function", function: %{
      name: "shell",
      description: "Your PRIMARY shell — runs entirely in WebAssembly (no OS process). Commands: cat echo seq head tail wc nl rev sort uniq tr basename dirname true false grep jq upper. Supports pipes (|), control flow (; && ||), variables (X=val then $X / ${X}), redirection (< > >>), and reading/writing files in your working dir. e.g. pipeline=\"cat data.json | jq .users[].name | sort -u\". `input` is optional stdin.",
      parameters: %{type: "object", properties: %{
        pipeline: %{type: "string", description: "a shell line, e.g. \"cat f.json | jq .x | sort -u > out.txt\""},
        input: %{type: "string", description: "optional stdin for the pipeline"}
      }, required: ["pipeline"]}
    }},
    %{type: "function", function: %{
      name: "search",
      description: "RECALL by meaning — semantic search over the org/code files in your working context (no separate memory store; the files ARE the memory). Returns the most relevant snippets with their path. Use this to recall what's known instead of re-deriving it. To 'remember' something, write it as an org file with vfs_write — it becomes searchable automatically. e.g. query=\"how do we handle auth headers\".",
      parameters: %{type: "object", properties: %{query: %{type: "string"}}, required: ["query"]}
    }},
    %{type: "function", function: %{
      name: "wb",
      description: "Run the wb CLI. Args as one string. Subcommands: `var set/get/list/ref` (variable store; secrets ref-only); `toolkit list` · `toolkit show <id> [skill]` (READ a skill recipe before using a toolkit) · `toolkit search <q>` · `toolkit run <id> <task> -- <args>`. e.g. args=\"toolkit show ffmpeg extract-audio\".",
      parameters: %{type: "object", properties: %{args: %{type: "string"}}, required: ["args"]}
    }},
    %{type: "function", function: %{
      name: "fetch",
      description: "HTTP GET a URL and return its page text (HTML stripped, truncated). Use to research a brand's website / fetch data.",
      parameters: %{type: "object", properties: %{url: %{type: "string"}}, required: ["url"]}
    }},
    %{type: "function", function: %{
      name: "vfs_write",
      description: "Write content to a path in your filesystem (persists across steps). Use for the deliverable, e.g. a brand-book HTML.",
      parameters: %{type: "object", properties: %{path: %{type: "string"}, content: %{type: "string"}}, required: ["path", "content"]}
    }},
    %{type: "function", function: %{
      name: "vfs_read",
      description: "Read a path from your filesystem.",
      parameters: %{type: "object", properties: %{path: %{type: "string"}}, required: ["path"]}
    }},
    %{type: "function", function: %{
      name: "done",
      description: "Finish the task. Provide the final result/answer.",
      parameters: %{type: "object", properties: %{result: %{type: "string"}}, required: ["result"]}
    }}
  ]

  # The tool surface for a run — the real-CLI `run` tool only when exec is granted.
  defp tools(%{exec: true}), do: [@run_tool | @base_tools]
  defp tools(_), do: @base_tools

  @doc """
  Run an agent to completion. `system` is the system prompt, `task` the user's
  request. opts: :model, :vfs (an open VFS conn), :max_steps. Returns a run record
  %{result, steps, events, log}.
  """
  def run(system, task, opts \\ []) do
    vfs = opts[:vfs] || elem(VFS.open(":memory:"), 1)

    st = %{
      vfs: vfs,
      model: opts[:model],
      tenant: opts[:tenant] || "dev",
      step: 0,
      max: opts[:max_steps] || 12,
      events: [],
      # exec: grant the real-CLI `run` tool (trusted agents). workdir/env scope it.
      exec: opts[:exec] || false,
      workdir: opts[:workdir] || System.tmp_dir!(),
      env: opts[:env] || [],
      # on_step.(event) fires as each tool step completes — for live streaming.
      on_step: opts[:on_step] || fn _ -> :ok end
    }

    messages = [%{role: "system", content: system}, %{role: "user", content: task}]
    loop(messages, st)
  end

  defp loop(_messages, %{step: step, max: max} = st) when step >= max,
    do: finish(st, "stopped: reached max_steps (#{max})")

  defp loop(messages, st) do
    case Llm.complete(messages, model: st.model, tools: tools(st)) do
      {:ok, %{tool_calls: [], content: content}} ->
        finish(st, content || "(no result)")

      {:ok, %{tool_calls: calls, raw_message: assistant}} ->
        {tool_msgs, st2, done} = exec_tools(calls, st)
        msgs = messages ++ [strip(assistant) | tool_msgs]
        if done, do: finish(st2, done), else: loop(msgs, %{st2 | step: st2.step + 1})

      {:error, e} ->
        finish(st, "error: #{inspect(e)}")
    end
  end

  defp exec_tools(calls, st) do
    Enum.reduce(calls, {[], st, nil}, fn call, {msgs, s, done} ->
      t0 = System.monotonic_time(:millisecond)
      {out, s2, d} = exec_one(call, Map.put(s, :last, %{}))
      meta = Map.get(s2, :last, %{})

      ev = %{
        step: s.step,
        tool: call.name,
        args: call.args,
        output: String.slice(out, 0, 4000),
        exit_code: meta[:exit_code],
        error: meta[:error],
        dur_ms: System.monotonic_time(:millisecond) - t0,
        ts: System.system_time(:second)
      }

      s.on_step.(ev)
      log_step(s2, ev)
      {msgs ++ [%{role: "tool", tool_call_id: call.id, content: out}], %{s2 | events: s2.events ++ [ev]}, done || d}
    end)
  end

  # Always-on per-tool telemetry — appended lock-free to <workdir>/_steps.jsonl
  # regardless of any caller-supplied on_step, so nothing escapes by construction.
  defp log_step(%{workdir: wd}, ev) when is_binary(wd) do
    line = Jason.encode!(%{ev | output: String.slice(ev.output || "", 0, 200)})
    File.write(Path.join(wd, "_steps.jsonl"), line <> "\n", [:append])
  rescue
    _ -> :ok
  end

  defp log_step(_, _), do: :ok

  defp exec_one(%{name: "shell", args: a}, st) do
    # Preopen the agent's workdir so shell commands can read/write its files
    # (e.g. `cat out.txt`) — files stay inside the sandbox, no host escape.
    case Shell.run(a["pipeline"], a["input"] || "", dirs: ["#{st.workdir}::#{st.workdir}"]) do
      {:ok, o} -> {o, st, nil}
      {:error, e} -> {"error: #{inspect(e)}", Map.put(st, :last, %{error: inspect(e)}), nil}
    end
  end

  defp exec_one(%{name: "run", args: a}, %{exec: true} = st) do
    # INTERIM: the real-bash escape hatch runs under the host isolator
    # (Workbooks.Sandbox — bwrap on Linux / seatbelt on macOS), not raw `sh -c`,
    # so it can't roam the container's fs/processes freely. run_net keeps network
    # (many native CLIs need it) but stays confined. NORTH STAR: no bash outside
    # WASM — every CLI/crate/npm becomes a WASM command and this tool is removed.
    {out, code} =
      Workbooks.Sandbox.run_net(["sh", "-c", a["cmd"] || ""], cd: st.workdir, env: st.env)

    # Capture the exit code — a non-zero is a bash call that broke; record it.
    meta = %{exit_code: code, error: if(code != 0, do: "nonzero exit #{code}", else: nil)}
    {String.slice(out, 0, 8000), Map.put(st, :last, meta), nil}
  catch
    kind, e -> {"run error: #{inspect({kind, e})}", Map.put(st, :last, %{error: inspect({kind, e})}), nil}
  end

  defp exec_one(%{name: "run"}, st), do: {"run not permitted (no exec capability)", st, nil}

  # Semantic recall over the agent's working org/code context — the files ARE the
  # memory (no separate store to drift). Stateless: always the current files.
  defp exec_one(%{name: "search", args: a}, st) do
    hits = Workbooks.Library.search_dir(st.workdir, a["query"] || "", k: 5)

    out =
      case hits do
        [] -> "(no relevant context found)"
        _ -> Enum.map_join(hits, "\n", fn h -> "[#{h.path}] #{h.headline}\n  #{String.slice(h.text, 0, 240) |> String.replace("\n", " ")}" end)
      end

    {out, st, nil}
  end

  defp exec_one(%{name: "fetch", args: a}, st), do: {fetch_url(a["url"]), st, nil}

  # Exec agents share an OS workdir (the substrate the toolkit CLIs + the next
  # agent read) — so their "filesystem" tools target that workdir, not the
  # per-agent in-memory VFS. Non-exec agents use the sandboxed VFS.
  defp exec_one(%{name: "vfs_write", args: a}, %{exec: true} = st) do
    path = in_workdir(st.workdir, a["path"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, a["content"] || "")
    {"wrote #{byte_size(a["content"] || "")} bytes to #{a["path"]}", st, nil}
  rescue
    e -> {"write error: #{Exception.message(e)}", st, nil}
  end

  defp exec_one(%{name: "vfs_write", args: a}, st) do
    VFS.put(st.vfs, a["path"], a["content"])
    {"wrote #{byte_size(a["content"] || "")} bytes to #{a["path"]}", st, nil}
  end

  defp exec_one(%{name: "vfs_read", args: a}, %{exec: true} = st) do
    out = case File.read(in_workdir(st.workdir, a["path"])) do
      {:ok, c} -> c
      {:error, r} -> "not found: #{a["path"]} (#{r})"
    end

    {out, st, nil}
  end

  defp exec_one(%{name: "vfs_read", args: a}, st) do
    out = case VFS.get(st.vfs, a["path"]) do
      {:ok, c} -> c
      :error -> "not found: #{a["path"]}"
    end

    {out, st, nil}
  end

  defp exec_one(%{name: "wb", args: a}, st) do
    argv = OptionParser.split(a["args"] || "")
    {Workbooks.CLI.call(argv, st.tenant), st, nil}
  end

  defp exec_one(%{name: "done", args: a}, st), do: {"ok", st, a["result"] || ""}
  defp exec_one(%{name: n}, st), do: {"unknown tool: #{n}", st, nil}

  # Resolve an agent-supplied path under the workdir. Absolute paths are used
  # as-is (the agent already knows the workdir) — else Path.join would DOUBLE it
  # (workdir/workdir/analysis/x.org), hiding files from `analysis check` + the
  # next agent. Relative paths join under the workdir.
  defp in_workdir(workdir, path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(workdir, path || "")
  end

  # Research fetch: GET a URL, strip HTML to readable text, truncate for the model.
  defp fetch_url(url) do
    :inets.start()
    :ssl.start()
    headers = [{~c"user-agent", ~c"Mozilla/5.0 (WorkbooksAgent)"}]

    case :httpc.request(:get, {String.to_charlist(url), headers}, [timeout: 20_000, autoredirect: true], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> body |> html_to_text() |> String.slice(0, 4000)
      {:ok, {{_, status, _}, _, _}} -> "fetch failed: HTTP #{status}"
      {:error, e} -> "fetch error: #{inspect(e)}"
    end
  end

  defp html_to_text(html) do
    html
    |> String.replace(~r/<script.*?<\/script>/si, " ")
    |> String.replace(~r/<style.*?<\/style>/si, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/&[a-z]+;/i, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Keep only the fields the API needs back (content + tool_calls).
  defp strip(assistant), do: Map.take(assistant, ["role", "content", "tool_calls"])

  defp finish(st, result) do
    log = event_log(st.events, result)
    VFS.put(st.vfs, "/events.org", log)
    %{result: result, steps: st.step, events: st.events, log: log}
  end

  # Org-mode event log — fully observable, OQL-queryable (like brandnana's events.org).
  defp event_log(events, result) do
    steps =
      Enum.map_join(events, "\n", fn ev ->
        """
        ** step #{ev.step}: #{ev.tool}                                  :tool_call:
           :PROPERTIES:
           :ARGS: #{Jason.encode!(ev.args)}
           :END:
           #{String.slice(ev.output, 0, 300) |> String.replace("\n", " ")}
        """
      end)

    "* Agent run                                                  :session:\n" <>
      steps <> "\n* Result\n  " <> String.replace(result, "\n", "\n  ") <> "\n"
  end
end

defmodule Workbooks.Agent do
  @moduledoc """
  The agent loop (the brandnana model, on the clean-room substrate). An agent is a
  BEAM loop: call the LLM → if it requests tools, run them → append results →
  loop, until the model stops calling tools or signals `done`. Long-horizon by
  construction (bounded by `max_steps`, resumable because state lives in the VFS).

  The clean-room improvement over brandnana's raw `bash`: the agent's tools are
  the *sandboxed in-WASM shell* (`Workbooks.Shell` over the CommandRegistry —
  jq/grep/upper) and the *VFS* (its filesystem). No OS shell, no ambient access.
  Every step is appended to an org-mode event log in the VFS (`events.org`) — the
  run is fully observable and OQL-queryable, like brandnana's events.org.
  """
  alias Workbooks.{Llm, Shell, VFS}

  # The real-CLI tool — only granted to trusted agents (opts[:exec]). It execs
  # toolkit CLIs (brandnana, wb, curl, jq) on PATH in the engine container, the
  # way the mainline strategist uses bash. Sandboxed by the container, not WASM.
  @run_tool %{type: "function", function: %{
    name: "run",
    description: "Run a real shell command (toolkit CLIs on PATH: brandnana, wb, curl, jq, cat, ls, …) in your working directory. Use for data/harvest verbs and reading files. Returns combined stdout+stderr (truncated). e.g. cmd=\"brandnana harvest-all tecovas.com\".",
    parameters: %{type: "object", properties: %{cmd: %{type: "string"}}, required: ["cmd"]}
  }}

  @base_tools [
    %{type: "function", function: %{
      name: "shell",
      description: "Run a pipeline of sandboxed WASM commands. Available commands: jq (filter, e.g. `jq .users[].name`), grep (regex match), upper (uppercase). NO cat/echo/sed — pass data via `input`. Example: pipeline=\"jq .users[].name\", input=<the JSON>. Returns stdout.",
      parameters: %{type: "object", properties: %{
        pipeline: %{type: "string", description: "command pipeline, e.g. \"jq .x | grep foo\""},
        input: %{type: "string", description: "stdin for the pipeline (e.g. the JSON to filter)"}
      }, required: ["pipeline"]}
    }},
    %{type: "function", function: %{
      name: "wb",
      description: "Run the wb CLI. Args as one string. Subcommands: `var set/get/list/ref` (variable store; secrets ref-only), `memory remember <key> <text>` / `memory recall <key>` / `memory search <q>` (your long-term memory — persists findings across runs). e.g. args=\"memory remember acme_color teal\".",
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
      {out, s2, d} = exec_one(call, s)
      ev = %{step: s.step, tool: call.name, args: call.args, output: String.slice(out, 0, 4000)}
      s.on_step.(ev)
      {msgs ++ [%{role: "tool", tool_call_id: call.id, content: out}], %{s2 | events: s2.events ++ [ev]}, done || d}
    end)
  end

  defp exec_one(%{name: "shell", args: a}, st) do
    out =
      case Shell.run(a["pipeline"], a["input"] || "") do
        {:ok, o} -> o
        {:error, e} -> "error: #{inspect(e)}"
      end

    {out, st, nil}
  end

  defp exec_one(%{name: "run", args: a}, %{exec: true} = st) do
    {out, _code} =
      System.cmd("sh", ["-c", a["cmd"] || ""], cd: st.workdir, stderr_to_stdout: true, env: st.env)

    {String.slice(out, 0, 8000), st, nil}
  catch
    kind, e -> {"run error: #{inspect({kind, e})}", st, nil}
  end

  defp exec_one(%{name: "run"}, st), do: {"run not permitted (no exec capability)", st, nil}

  defp exec_one(%{name: "fetch", args: a}, st), do: {fetch_url(a["url"]), st, nil}

  # Exec agents share an OS workdir (the substrate the toolkit CLIs + the next
  # agent read) — so their "filesystem" tools target that workdir, not the
  # per-agent in-memory VFS. Non-exec agents use the sandboxed VFS.
  # Resolve an agent-supplied path under the workdir. Absolute paths are used
  # as-is (the agent already knows the workdir) — else Path.join would DOUBLE it
  # (workdir/workdir/analysis/x.org), hiding files from `analysis check` + the
  # next agent. Relative paths join under the workdir.
  defp in_workdir(workdir, path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(workdir, path || "")
  end

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

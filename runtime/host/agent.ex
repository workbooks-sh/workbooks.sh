defmodule Workbooks.Agent do
  @moduledoc """
  The agent loop (the brandnana model, on the clean-room substrate). An agent is a
  BEAM loop: call the LLM → if it requests tools, run them → append results →
  loop, until the model stops calling tools or signals `done`. Long-horizon by
  construction (bounded by `max_steps`, resumable because state lives in the VFS).

  The clean-room improvement over brandnana's raw `bash`: the agent's primary tool
  is the *sandboxed in-WASM shell* (`Workbooks.Shell` over the CommandRegistry —
  coreutils + jq/grep, pipes, `; && ||`, vars, redirection, workdir files) and the
  *VFS*. There is NO OS shell at all: the old `run` escape hatch (real native bash)
  was DELETED (wb-9ja). It is by construction IMPOSSIBLE for the agent to execute
  native code — the tool surface exposes only the in-WASM `shell`, the VFS, and a
  handful of HOST-BROKERED capabilities (`git`, `publish`, `fetch`, `wb`) that
  trusted host Elixir performs on the agent's behalf. The agent never shells out.
  Every step is appended to an org-mode event log in the VFS (`events.org`) — the
  run is fully observable and OQL-queryable, like brandnana's events.org.
  """
  require Logger
  alias Workbooks.{Shell, VFS}

  # HOST-BROKERED tools — only granted to trusted (exec) agents. These let the
  # keeper agent (Waldo) commit/push and publish to the site WITHOUT any native
  # exec from the agent: the agent calls the TOOL, trusted host Elixir
  # (Workbooks.Git / File.cp) runs git / copies files. The agent itself never
  # forks a process. This is what replaced the deleted native `run` hatch (wb-9ja).
  #
  # WHY this is not "native execution by the agent": running native code on behalf
  # of the agent is fine when the HOST decides exactly what runs (a fixed
  # `git commit && git push`, a constrained File.cp into the public dir). The ban
  # is on the AGENT choosing an arbitrary native command line — that capability no
  # longer exists in the tool surface.
  @exec_tools [
    %{type: "function", function: %{
      name: "git",
      description: "Commit all changes in your working dir and push (host-brokered — you do NOT run git yourself; the host commits + pushes your repo). Use after you've written your changes. e.g. message=\"add: how-it-works section\".",
      parameters: %{type: "object", properties: %{
        message: %{type: "string", description: "the commit message"}
      }, required: ["message"]}
    }},
    %{type: "function", function: %{
      name: "publish",
      description: "Publish your changed content to the LIVE public site (host-brokered host File copy — no shell). Copies content/** and blog/** from your working dir to the public web root so it appears on the page. Call after writing content. No args.",
      parameters: %{type: "object", properties: %{}, required: []}
    }},
    %{type: "function", function: %{
      name: "image",
      description: "Generate an editorial image — a banner or illustration — for the page (host-brokered: you supply the INTENT, the host holds the key + network and writes the file). BUDGET: 2 per run — plan your banners, don't spray. Write under content/images/ (e.g. content/images/deepmind-banner.webp). NEVER put text/words/captions in the image (typography goes in HTML, not pixels). e.g. prompt=\"abstract DeepMind hero, deep blues + neural mesh\", path=\"content/images/deepmind-banner.webp\", aspect=\"16:9\".",
      parameters: %{type: "object", properties: %{
        prompt: %{type: "string", description: "what the image depicts (no text in the image)"},
        path: %{type: "string", description: "workdir-relative output path under content/images/, e.g. content/images/x.webp"},
        aspect: %{type: "string", description: "16:9 (default) | 1:1 | 3:1"}
      }, required: ["prompt", "path"]}
    }}
  ]

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
      name: "web_search",
      description: "Search the WEB by query — returns the top results as title · url · snippet. Keyless (DuckDuckGo/Brave/Bing, host-brokered). This is how you do real research: find what exists, who reported it, then `fetch` the primary sources. Use for SERP scans, finding sources, market/landscape research. e.g. query=\"anthropic fable launch\".",
      parameters: %{type: "object", properties: %{query: %{type: "string"}}, required: ["query"]}
    }},
    %{type: "function", function: %{
      name: "file_issue",
      description: "When you hit a WALL — a capability/tool/skill you NEED that does not exist, a rule that blocks you, a thing you cannot do in your sandbox — FILE IT here instead of stalling, faking, or working around it. The autopoet (the system's self-improvement agent) works these down and grows the capability. Be specific: what you needed, what you tried, how it failed. Filing readily is encouraged — the backlog dedupes. e.g. title=\"no way to POST to a SERP API\", need=\"web search\", tried=\"fetch is GET-only; no curl\".",
      parameters: %{type: "object", properties: %{title: %{type: "string"}, need: %{type: "string"}, tried: %{type: "string"}}, required: ["title"]}
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

  # The tool surface for a run. Trusted (exec) agents additionally get the
  # HOST-BROKERED git/publish tools — never a native-exec tool (the `run` hatch is
  # gone, wb-9ja). So no path here can hand the agent native code execution.
  defp tools(%{exec: true}), do: @exec_tools ++ @base_tools
  defp tools(_), do: @base_tools

  @doc false
  # Test-only window onto the tool surface (used by no_native_exec_test to assert,
  # by construction, that no native-exec tool is ever exposed). opts: [exec: bool].
  def __tool_names_for_test__(opts) do
    st = %{exec: Keyword.get(opts, :exec, false)}
    tools(st) |> Enum.map(& &1.function.name)
  end

  @doc false
  # Test-only window onto a single tool execution (used by image_gen_test to
  # exercise the `image` tool's budget + path guard + decode/write without driving
  # the full LLM loop). `st0` is a partial run state; returns {output, new_state}.
  def __exec_one_for_test__(call, st0) do
    {out, st, _done} = exec_one(call, st0)
    {out, st}
  end

  @doc """
  Run an agent to completion. `system` is the system prompt, `task` the user's
  request. opts: :model, :vfs (an open VFS conn), :max_steps, :agent (the crew
  member's display name — tags every step + thought with its identity, wb-wc0.2).
  Returns a run record %{result, steps, events, log}.
  """
  def run(system, task, opts \\ []) do
    vfs = opts[:vfs] || elem(VFS.open(":memory:"), 1)

    st = %{
      vfs: vfs,
      model: opts[:model],
      # The crew member's name (nil for the singleton). Stamped onto every step
      # event so /_activity can group the live wire by agent (wb-wc0.2 §3).
      agent: opts[:agent],
      tenant: opts[:tenant] || "dev",
      step: 0,
      max: opts[:max_steps] || 12,
      events: [],
      # exec: a TRUST flag for the keeper/brandnana agents. It grants the
      # host-brokered git/publish tools and routes the filesystem tools at the OS
      # workdir (the shared substrate) instead of the in-memory VFS. It NO LONGER
      # grants any native execution — the `run` hatch was removed (wb-9ja).
      exec: opts[:exec] || false,
      # Per-run image budget: the `image` tool is brokered + costs money/latency,
      # so it's capped at 2 calls/run (counted here, threaded through exec_one).
      images_used: 0,
      workdir: opts[:workdir] || System.tmp_dir!(),
      env: opts[:env] || [],
      # on_step.(event) fires as each tool step completes — for live streaming.
      on_step: opts[:on_step] || fn _ -> :ok end,
      # on_delta.(chunk) fires per text token as the model generates — for
      # token-by-token streaming of the agent's reply. nil-op by default.
      on_delta: opts[:on_delta] || fn _ -> :ok end,
      # Set once we've nudged the model for a final answer after a silent
      # dead-stop (empty content + no tool call). Guards against re-nudging.
      summarized: false,
      # The LLM completion fn — injectable so the loop is testable without the
      # network (default is the real Llm.complete/2). Same {messages, opts} shape.
      complete_fn: opts[:complete_fn] || (&Workbooks.Llm.complete/2)
    }

    messages = [%{role: "system", content: system}, %{role: "user", content: task}]
    loop(messages, st)
  end

  defp loop(_messages, %{step: step, max: max} = st) when step >= max,
    do: finish(st, "stopped: reached max_steps (#{max})")

  defp loop(messages, st) do
    case st.complete_fn.(messages, model: st.model, tools: tools(st), on_delta: st.on_delta) do
      {:ok, %{tool_calls: [], content: content}} ->
        cond do
          content not in [nil, ""] ->
            finish(st, content)

          # Silent dead-stop: the model returned empty content with no tool call
          # (common on cheap models — whether after tool use, or even a first-turn
          # hiccup). Nudge ONCE for a real answer so the user (and the eval judge)
          # never gets "(no result)" when a reply was recoverable. The summarized
          # flag guards against re-nudging forever.
          not st.summarized ->
            nudge = %{
              role: "user",
              content:
                "Please give your answer to my request now, in plain language" <>
                  if(st.step > 0, do: " using what your tools returned", else: "") <>
                  ". Don't call any more tools."
            }

            loop(messages ++ [nudge], %{st | summarized: true, step: st.step + 1})

          true ->
            finish(st, content || "(no result)")
        end

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
      # step-start marker: if a run stalls, the logs show what was in flight
      Logger.info("agent: step #{s.step} #{call.name} starting")
      t0 = System.monotonic_time(:millisecond)
      {out, s2, d} = exec_bounded(call, Map.put(s, :last, %{}))
      meta = Map.get(s2, :last, %{})

      ev = %{
        step: s.step,
        # Per-agent identity (wb-wc0.2): nil for the singleton, the crew member's
        # name otherwise. Carried into _steps.jsonl so the activity wire can group.
        agent: s.agent,
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

  # EVERY tool call is wall-clock bounded (150s): any wedged tool — sqlite,
  # network, a host-brokered git push — surfaces as a tool error the model can
  # react to, never a stalled run.
  defp exec_bounded(call, st) do
    # A tool that RAISES (e.g. `wb model "get` → OptionParser.split unbalanced
    # quote) must become a clean tool-error the agent can react to — never crash
    # the whole run via the linked Task. Catch exceptions + non-local exits here.
    task =
      Task.async(fn ->
        try do
          exec_one(call, st)
        rescue
          e -> {"tool error: #{call.name} raised — #{Exception.message(e)}", Map.put(st, :last, %{error: Exception.message(e)}), nil}
        catch
          kind, reason -> {"tool error: #{call.name} #{kind} — #{inspect(reason)}", Map.put(st, :last, %{error: inspect(reason)}), nil}
        end
      end)

    case Task.yield(task, 150_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      _ ->
        {"tool error: #{call.name} timed out after 150s (killed)",
         Map.put(st, :last, %{error: "tool timeout"}), nil}
    end
  end

  defp exec_one(%{name: "shell", args: a}, st) do
    # Preopen the agent's workdir so shell commands can read/write its files
    # (e.g. `cat out.txt`) — files stay inside the sandbox, no host escape.
    # A malformed call (missing/non-string pipeline) bounces back to the model
    # as an error message — never a crash.
    case a["pipeline"] do
      p when is_binary(p) ->
        case Shell.run(p, a["input"] || "", dirs: ["#{st.workdir}::#{st.workdir}"]) do
          {:ok, o} -> {o, st, nil}
          {:error, e} -> {"error: #{inspect(e)}", Map.put(st, :last, %{error: inspect(e)}), nil}
        end

      _ ->
        {"shell error: required arg `pipeline` missing or not a string", Map.put(st, :last, %{error: "missing pipeline"}), nil}
    end
  end

  # HOST-BROKERED git: commit ALL changes in the agent's workdir + push, run by
  # trusted host Elixir (Workbooks.Git, which itself uses System.cmd git on ITS
  # OWN repos — host infrastructure, NOT the agent running native code). The agent
  # supplies only a commit message; it can never choose the command line. This is
  # the replacement for the deleted `run` hatch's git add/commit/push usage.
  defp exec_one(%{name: "git", args: a}, %{exec: true} = st) do
    msg = to_string(a["message"] || "agent update")

    case Workbooks.Git.commit_and_push(st.workdir, msg, st.tenant) do
      {:ok, info} -> {"committed + pushed: #{info}", st, nil}
      {:nochange, _} -> {"nothing to commit (working tree clean)", st, nil}
      {:error, reason} -> {"git error: #{inspect(reason)}", Map.put(st, :last, %{error: inspect(reason)}), nil}
    end
  end

  defp exec_one(%{name: "git"}, st), do: {"git not permitted (no exec capability)", st, nil}

  # HOST-BROKERED publish: copy the agent's content (content/** + blog/**) from its
  # workdir to the public site dir, by host File ops (File.cp — no shell). The agent
  # picks nothing about HOW the copy runs; the host owns the source/dest contract.
  # Replaces the `run` hatch's `cp/mkdir` publish step from agent.org step 6.
  defp exec_one(%{name: "publish"}, %{exec: true} = st) do
    case Workbooks.SitePublish.publish(st.workdir, st.tenant) do
      {:ok, n} -> {"published #{n} file(s) to the live site", st, nil}
      {:error, reason} -> {"publish error: #{inspect(reason)}", Map.put(st, :last, %{error: inspect(reason)}), nil}
    end
  end

  defp exec_one(%{name: "publish"}, st), do: {"publish not permitted (no exec capability)", st, nil}

  # HOST-BROKERED image generation: the agent supplies a prompt + a workdir path;
  # trusted host Elixir (Workbooks.ImageGen) calls OpenRouter's image lane with the
  # host-held key and writes the decoded bytes via pure File ops. The agent never
  # sees the key, the endpoint, or a subprocess. Path-traversal guarded exactly like
  # publish (the written file must resolve strictly inside the workdir). Budget: 2
  # image calls per run — counted in `images_used` and threaded through run state.
  @image_budget 2
  defp exec_one(%{name: "image"}, %{exec: true, images_used: used} = st)
       when used >= @image_budget do
    {"image budget exhausted (#{@image_budget}/run) — plan banners, don't spray", st, nil}
  end

  defp exec_one(%{name: "image", args: a}, %{exec: true} = st) do
    prompt = to_string(a["prompt"] || "")
    rel = to_string(a["path"] || "")
    aspect = a["aspect"] || "16:9"
    dest = in_workdir(st.workdir, rel)

    cond do
      prompt == "" ->
        {"image error: required arg `prompt` is empty", st, nil}

      rel == "" ->
        {"image error: required arg `path` is empty", st, nil}

      not image_contained?(st.workdir, dest) ->
        {"image error: path escapes your working dir (#{rel}) — write under content/images/", st, nil}

      true ->
        # Count the call against the budget the moment it's attempted (a failed
        # generation still spent the budgeted slot — keeps the cap honest).
        st = %{st | images_used: st.images_used + 1}

        case Workbooks.ImageGen.generate(prompt, aspect) do
          {:ok, bin} ->
            File.mkdir_p!(Path.dirname(dest))
            File.write!(dest, bin)
            {"ok #{rel} (#{byte_size(bin)} bytes)", st, nil}

          {:error, reason} ->
            {"image error: #{inspect(reason)}", Map.put(st, :last, %{error: inspect(reason)}), nil}
        end
    end
  rescue
    e -> {"image error: #{Exception.message(e)}", st, nil}
  end

  defp exec_one(%{name: "image"}, st), do: {"image not permitted (no exec capability)", st, nil}

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

  # web_search: host-brokered keyless SERP (the research capability the agents
  # lost when the native `run`/curl hatch was removed — wb-9ja — which silently
  # blocked all SERP work and made the lander mislabel itself "env-gated"). No
  # keys, no native exec; the host queries the engine and returns parsed results.
  defp exec_one(%{name: "web_search", args: a}, st) do
    out =
      case Workbooks.Browse.Search.query(a["query"] || "", limit: 8) do
        [] -> "no results"
        hits ->
          Enum.map_join(hits, "\n", fn h ->
            "• #{h.title}\n  #{h.url}#{if h[:snippet] && h.snippet != "", do: "\n  " <> String.slice(h.snippet, 0, 160), else: ""}"
          end)
      end

    {out, st, nil}
  end

  # file_issue: the metacognitive seam (wb-9ae). An agent that hits a wall files
  # it instead of stalling/faking — the lander mislabeling "no web search" as
  # "env-gated" for 6h is exactly what this prevents.
  defp exec_one(%{name: "file_issue", args: a}, st) do
    out =
      case Workbooks.Autopoet.file_issue(%{
             title: a["title"],
             need: a["need"],
             tried: a["tried"],
             tenant: st[:agent] || st[:tenant] || System.get_env("WB_TENANT")
           }) do
        {:ok, id} -> "issue filed (#{id}) — the autopoet will work it. Note this in your run, then carry on with what you CAN do; do not stall on the gap."
        {:error, e} -> "could not file issue: #{inspect(e)}"
      end

    {out, st, nil}
  end

  # Exec agents share an OS workdir (the substrate the toolkit CLIs + the next
  # agent read) — so their "filesystem" tools target that workdir, not the
  # per-agent in-memory VFS. Non-exec agents use the sandboxed VFS.
  defp exec_one(%{name: "vfs_write", args: a}, %{exec: true} = st) do
    case safe_path(st.workdir, a["path"]) do
      {:ok, path} ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, a["content"] || "")
        {"wrote #{byte_size(a["content"] || "")} bytes to #{a["path"]}", st, nil}

      :escape ->
        {"write blocked: path escapes your working dir (#{a["path"]}) — you can only write inside it", st, nil}
    end
  rescue
    e -> {"write error: #{Exception.message(e)}", st, nil}
  end

  defp exec_one(%{name: "vfs_write", args: a}, st) do
    VFS.put(st.vfs, a["path"], a["content"])
    {"wrote #{byte_size(a["content"] || "")} bytes to #{a["path"]}", st, nil}
  end

  defp exec_one(%{name: "vfs_read", args: a}, %{exec: true} = st) do
    out =
      case safe_path(st.workdir, a["path"]) do
        {:ok, path} ->
          case File.read(path) do
            {:ok, c} -> c
            {:error, r} -> "not found: #{a["path"]} (#{r})"
          end

        :escape ->
          "read blocked: path escapes your working dir (#{a["path"]})"
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

    # `wb deploy` reaches infra-modifying, non-tenant-scoped Deploy Kit ops, so it
    # is gated by the exec capability like git/publish — the trusted desktop may
    # deploy; an exec-denied (cloud/shared) tenant's agent must not. The read +
    # tenant-scoped verbs (model/var/app/env/telemetry/ledger/…) stay ungated.
    if effectful_wb?(argv) and not Map.get(st, :exec, false) do
      {"wb #{List.first(argv)} not permitted (no exec capability)", st, nil}
    else
      {Workbooks.CLI.call(argv, st.tenant), st, nil}
    end
  end

  defp exec_one(%{name: "done", args: a}, st), do: {"ok", st, a["result"] || ""}
  defp exec_one(%{name: n}, st), do: {"unknown tool: #{n}", st, nil}

  # Verbs that affect the host/infra (not tenant-scoped) → require exec.
  defp effectful_wb?(["deploy" | _]), do: true
  defp effectful_wb?(_), do: false

  # Resolve an agent-supplied path under the workdir. Absolute paths are used
  # as-is (the agent already knows the workdir) — else Path.join would DOUBLE it
  # (workdir/workdir/analysis/x.org), hiding files from `analysis check` + the
  # next agent. Relative paths join under the workdir.
  defp in_workdir(workdir, path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(workdir, path || "")
  end

  # Path-traversal guard for image writes — the resolved dest must sit strictly
  # inside the workdir (mirrors SitePublish.contained?). Blocks `..` escapes and
  # absolute paths pointing outside the sandbox workdir.
  defp image_contained?(workdir, dest) do
    String.starts_with?(Path.expand(dest) <> "/", Path.expand(workdir) <> "/")
  end

  # Resolve an agent path AND enforce containment: the file tools (vfs_read/
  # vfs_write) must not escape the workdir. Without this an exec agent could
  # read/write any host file (`/etc/passwd`, host `*.ex`, another tenant's repo,
  # secrets) via an absolute path or `../` — the hole that made the autopoet's
  # "confined to the config layer" claim false. `:escape` is returned for any
  # path resolving outside the workdir.
  defp safe_path(workdir, rel) do
    abs = in_workdir(workdir, rel)
    if image_contained?(workdir, abs), do: {:ok, abs}, else: :escape
  end

  @doc false
  # test seam for the containment guard (security-critical — see safe_path/2)
  def safe_path_for_test(workdir, rel), do: safe_path(workdir, rel)

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

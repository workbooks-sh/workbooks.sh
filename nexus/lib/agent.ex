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
  @reg {__MODULE__, :agents}

  # The autopoet-management postures (Autopoiesis v2 — wb-a6u3.3). Default `managed`.
  @management_levels ~w(managed proposed frozen)
  @default_management "managed"

  # The human-gated STRUCTURAL TRIAD — fields the autopoet may never autonomously change (the merge
  # gate, wb-a6u3.4, enforces this). Capability (`grant`), the subtree boundary (`ceiling`, declared in
  # `index.work`), and the management posture itself. Everything else about a `managed` agent is fair
  # game for autonomous, within-ceiling editing.
  @structural_triad ~w(grant ceiling management)a

  @doc "The autopoet-management postures: managed | proposed | frozen."
  def management_levels, do: @management_levels

  @doc "The human-gated structural-triad field names (grant, ceiling, management)."
  def structural_triad, do: @structural_triad

  @doc "An agent node's management posture — `managed` (default) | `proposed` | `frozen`."
  def management(node) do
    case def_from_unit(node) do
      %{management: m} -> m
      _ -> @default_management
    end
  end

  @doc "May the autopoet edit this agent AUTONOMOUSLY (within ceiling)? Only `managed` agents."
  def autopoet_managed?(node), do: management(node) == "managed"

  @doc "Register a declared `agent` unit by name (called at workbook bringup) for run-by-name."
  def register(%{kind: "agent", name: name} = node) do
    :persistent_term.put(@reg, Map.put(agents(), to_string(name), node))
    :ok
  end

  @doc "A registered agent node by name, or nil."
  def get(name), do: Map.get(agents(), to_string(name))

  @doc "All registered agent nodes."
  def all, do: agents() |> Map.values()

  defp agents, do: :persistent_term.get(@reg, %{})

  @doc "Run a DECLARED agent by name (resolves its prompt/tools/grant/limit). `{:error, {:no_agent, n}}` if unknown."
  def run_named(name, task, opts \\ []) do
    case get(name) do
      nil -> {:error, {:no_agent, to_string(name)}}
      node -> run_unit(node, task, opts)
    end
  end

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
    # Inline runs use the same field names as the `agent` block: `prompt`/`tools`. Normalize to the
    # internal `system`/`kits` so `run(prompt:, tools:, grant:, limit:, task:)` matches the block.
    opts = opts |> rename_opt(:prompt, :system) |> rename_opt(:tools, :kits)
    task = Keyword.fetch!(opts, :task)
    {vfs, finalize} = setup_vfs(opts, task)
    for {path, contents} <- Keyword.get(opts, :seed, %{}), do: Vfs.put(vfs, path, contents)

    messages = [%{role: "system", content: system_prompt(opts)}, %{role: "user", content: task}]
    timeout = Keyword.get(Keyword.get(opts, :limit, []), :timeout, Keyword.get(opts, :timeout_ms, @default_timeout))
    deadline = now_ms() + timeout
    started = now_ms()

    try do
      {result, tel} = loop(messages, vfs, opts, deadline, %{turns: 0, prompt: 0, completion: 0, total: 0, tools: []})
      record_run(opts[:unit], result, tel, started)
      finalize.(result)
    after
      Vfs.destroy(vfs)
    end
  end

  # Choose the agent's /work. A WORKSPACE-SCOPED run (opts[:workspace] = %{bare, work_dir, name, ...})
  # runs in a real jj WORKTREE of the workspace branch — the wasm sandbox preopens it, the agent edits
  # real files, and on success we seal them as an attributed commit on the agent's branch. An ephemeral
  # run (no workspace, or jj unavailable) uses a throwaway scratch dir, exactly as before. Returns
  # `{vfs, finalize_fn}` where finalize runs AFTER the loop with the run result.
  defp setup_vfs(opts, task) do
    with true <- Nexus.JJ.substrate?(),
         %{bare: bare, work_dir: work_dir, name: name} = ws <- Keyword.get(opts, :workspace),
         uniq <- System.unique_integer([:positive]),
         wsname <- "agent-#{name}-#{uniq}",
         dest <- Path.join(System.tmp_dir!(), "nexus_wt_#{name}_#{uniq}"),
         {:ok, _} <- Nexus.JJ.workspace_add(bare, work_dir, wsname, dest) do
      branch = Map.get(ws, :branch, "agent/#{name}")
      author = Map.get(ws, :author, "#{name} <#{name}>")
      message = Map.get(ws, :message, "#{name}: #{String.slice(task, 0, 80)}")
      # Workflow mode: "fifo" (default) auto-integrates the sealed branch into main (jj-FIFO + undo);
      # "review" leaves the branch for a PR / reviewer agent (the per-subtree workflow config picks).
      mode = Map.get(ws, :mode, "fifo")

      finalize = fn result ->
        with {:ok, _} <- result,
             {:ok, _sha} <- Nexus.JJ.workspace_commit(dest, message, author, branch) do
          if mode == "fifo", do: Nexus.JJ.integrate(bare, work_dir, branch, "main")
        end

        Nexus.JJ.workspace_forget(work_dir, wsname, dest)
        result
      end

      {Vfs.attach(dest), finalize}
    else
      _ -> {Vfs.new(), fn result -> result end}
    end
  end

  # fold each run into the execution-reality ledger (§10), keyed by unit identity.
  defp record_run(unit, result, tel, started) do
    status =
      case result do
        {:ok, _} -> :ok
        {:error, {:timeout, _}} -> :timeout
        {:error, _} -> :error
      end

    Nexus.Telemetry.record(unit, %{
      at: started,
      turns: tel.turns,
      tokens: %{prompt: tel.prompt, completion: tel.completion, total: tel.total},
      latency_ms: now_ms() - started,
      tools: Enum.frequencies(tel.tools),
      status: status,
      error: if(status == :error, do: inspect(elem(result, 1)))
    })
  end

  # accumulate a turn's token usage + the kits it invoked into the telemetry acc.
  defp tally(tel, turn, calls) do
    u = Map.get(turn, :usage, %{})

    %{
      tel
      | turns: tel.turns + 1,
        prompt: tel.prompt + (u["prompt_tokens"] || 0),
        completion: tel.completion + (u["completion_tokens"] || 0),
        total: tel.total + (u["total_tokens"] || 0),
        tools: tel.tools ++ Enum.map(calls, &kit_of/1)
    }
  end

  # the kit a bash tool-call exercised — the first token of the command.
  defp kit_of(%{args: %{"command" => cmd}}) when is_binary(cmd) do
    cmd |> String.trim_leading() |> String.split(~r/\s+/, parts: 2) |> List.first() || "bash"
  end

  defp kit_of(_), do: "bash"

  @doc """
  Build a runnable agent def from a parsed `agent` unit node — an agent authored as a literate
  function in a `.work` file (`agent :name do <system prompt> end`). Returns `%{name, system}`.
  """
  def def_from_unit(%{kind: "agent", name: name} = node) do
    case structured(node[:ast]) do
      {:ok, fields} -> Map.put(fields, :name, name)
      :no -> %{name: name, system: String.trim(node[:body] || "")}
    end
  end

  # A STRUCTURED agent block — `agent :x do prompt "…"; tools …; grant …; limit … end` — parses to a
  # real AST we read fields off. `prompt` is the system prompt; `tools`/`grant` scope capabilities;
  # `limit` sets guardrails (turns/timeout). Each field is composable Elixir (atoms, lists, or refs).
  # A bare-prose body doesn't parse as Elixir (ast: nil) and falls back to body-as-prompt.
  defp structured({:agent, _, args}) when is_list(args) do
    with block when not is_nil(block) <- Enum.find_value(args, fn [{:do, b}] -> b; _ -> nil end),
         fields when fields != %{} <- Enum.reduce(block_stmts(block), %{}, &collect_field/2) do
      {:ok, Map.put_new(fields, :system, "")}
    else
      _ -> :no
    end
  end

  defp structured(_), do: :no

  defp block_stmts({:__block__, _, s}), do: s
  defp block_stmts(nil), do: []
  defp block_stmts(one), do: [one]

  defp collect_field({:prompt, _, [p]}, acc) when is_binary(p), do: Map.put(acc, :system, String.trim(p))
  defp collect_field({:tools, _, a}, acc), do: Map.put(acc, :tools, names(a))
  # grants are validated against the real capability vocabulary — a typo/fake cap is dropped, not
  # silently honored, so an agent's declared powers are exactly the ones the runtime can enforce.
  defp collect_field({:grant, _, a}, acc),
    do: Map.put(acc, :grant, names(a) |> Enum.filter(&Nexus.Capabilities.grantable?/1))

  defp collect_field({:limit, _, [kw]}, acc) when is_list(kw),
    do: Map.put(acc, :limit, Keyword.take(kw, [:turns, :timeout]))

  # `management managed|proposed|frozen` — the autopoet-management posture of THIS agent (Autopoiesis
  # v2). `managed` = the autopoet may edit it autonomously within ceiling; `proposed` = the autopoet
  # proposes, a human merges; `frozen` = the autopoet may not touch it (injection-exposed/high-trust;
  # the autopoet carries `frozen` on itself). Unknown/absent → the safe-to-improve default `managed`.
  # The tag itself is part of the human-gated structural triad — an agent can never autonomously flip
  # it (enforced by the merge gate), so it can't promote itself into the autopoet's reach.
  defp collect_field({:management, _, a}, acc) do
    case names(a) do
      [lvl | _] when lvl in @management_levels -> Map.put(acc, :management, lvl)
      _ -> Map.put(acc, :management, @default_management)
    end
  end

  # OPEN spec: any other declared field (context, safety, hooks, model, …) is captured generically,
  # so the block can declare it today and the runtime honors each as it's wired. The agent definition
  # surface isn't a fixed four fields — it's whatever the block states.
  defp collect_field({key, _, args}, acc) when is_atom(key), do: Map.put(acc, key, field_value(args))
  defp collect_field(_, acc), do: acc

  defp field_value([v]) when is_binary(v), do: v
  defp field_value([kw]) when is_list(kw), do: kw
  defp field_value(args), do: names(args)

  # Normalize a field's args to names: atoms (`:fs`), bare identifiers (`fs` → var AST), or a list
  # literal (`[fs, exec]`). Anything else stringifies so composition/refs stay open.
  defp names(args) do
    args
    |> Enum.flat_map(fn list when is_list(list) -> list; other -> [other] end)
    |> Enum.map(fn
      a when is_atom(a) -> Atom.to_string(a)
      {id, _, ctx} when is_atom(id) and is_atom(ctx) -> Atom.to_string(id)
      other -> Macro.to_string(other)
    end)
  end

  @doc "Run an `agent` unit node on `task`. Threads the block's prompt + tools/grant/limit into run/1."
  def run_unit(node, task, opts \\ []) do
    d = def_from_unit(node)

    # Effective grant = declared ∩ ceiling, on EVERY run (Autopoiesis v2 — wb-a6u3.2). Two ceilings
    # compose, and each can only ever DROP capability, never add:
    #   • the INDEX ceiling governing the agent's subtree — resolved at bringup into `node[:ceiling]`
    #     from the `index.work` hierarchy (the durable, out-of-reach boundary; `:unbounded` when the
    #     agent's location isn't known to this run);
    #   • the parent's spawn ceiling (`:grant_ceiling`) — a delegated sub-agent can never exceed its
    #     parent's grants.
    # So editing a declared grant UP is a no-op: it is intersected back down to what the ceiling allows.
    index_ceiling = Keyword.get(opts, :ceiling) || Map.get(node, :ceiling) || :unbounded
    grant = effective_grant(d[:grant], index_ceiling, Keyword.get(opts, :grant_ceiling))

    base =
      [system: d.system, task: task, unit: d.name]
      |> put_if(:kits, d[:tools])
      |> put_if(:grant, grant)
      |> put_if(:limit, d[:limit])

    result = run(Keyword.merge(base, opts) |> Keyword.drop([:grant_ceiling, :ceiling]))

    # #event auto-instrument: a #event-tagged agent emits an event on each run (agent → event → hook).
    answer = with {:ok, %{answer: a}} <- result, do: a, else: (_ -> nil)
    Nexus.Events.instrument(node, %{kind: "agent.#{d.name}", actor: to_string(d.name), title: task, result: answer})

    result
  end

  @doc """
  A declared grant clamped to the index ceiling and the parent spawn ceiling — `declared ∩ each`. A
  `nil`/`:unbounded` ceiling imposes no constraint; a `nil` declared grant stays `nil` (no grant block
  = all powers, back-compat). This is the one comparison the whole ceiling model rests on: capability
  only ever flows DOWN, so no self-edit (or sub-agent spawn) can escalate.
  """
  def effective_grant(declared, index_ceiling, parent_ceiling) do
    declared |> clamp(index_ceiling) |> clamp(parent_ceiling)
  end

  defp clamp(declared, ceiling) when is_list(declared) and is_list(ceiling),
    do: Enum.filter(declared, &(&1 in ceiling))

  defp clamp(declared, _ceiling), do: declared

  defp put_if(kw, _key, nil), do: kw
  defp put_if(kw, key, val), do: Keyword.put(kw, key, val)

  defp rename_opt(kw, from, to) do
    case Keyword.fetch(kw, from) do
      {:ok, v} -> kw |> Keyword.delete(from) |> Keyword.put_new(to, v)
      :error -> kw
    end
  end

  defp loop(messages, vfs, opts, deadline, tel) do
    emit = Keyword.get(opts, :on_event, fn _ -> :ok end)
    # Generic typed side-channel (default no-op) — feeds the SSE streaming endpoint. Additive: it
    # carries map events keyed by :type and never changes loop's return value.
    stream = Keyword.get(opts, :emit, fn _ -> :ok end)

    max_turns = Keyword.get(Keyword.get(opts, :limit, []), :turns)

    cond do
      now_ms() > deadline ->
        stream.(%{type: "error", error: inspect({:timeout, tel.turns})})
        {{:error, {:timeout, tel.turns}}, tel}

      is_integer(max_turns) and tel.turns >= max_turns ->
        stream.(%{type: "error", error: "turn limit #{max_turns} reached"})
        {{:error, {:turn_limit, max_turns}}, tel}

      true ->
        case Nexus.Llm.complete(manage(messages, opts), Keyword.put(opts, :tools, [@bash_tool])) do
        {:ok, %{tool_calls: []} = turn} ->
          if reasoning?(turn.content), do: emit.({:answer, turn.content})
          stream.(%{type: "final", answer: turn.content})
          tel = tally(tel, turn, [])
          {{:ok, %{answer: turn.content, turns: tel.turns, vfs_files: Vfs.ls(vfs)}}, tel}

        {:ok, %{tool_calls: calls} = turn} ->
          if reasoning?(turn.content), do: emit.({:think, turn.content})
          if reasoning?(turn.content), do: stream.(%{type: "text", content: turn.content})
          stream.(%{type: "tools", count: length(calls), commands: Enum.map(calls, &command_of/1)})
          Enum.each(calls, fn c -> emit.({:tool, command_of(c)}) end)
          tel = tally(tel, turn, calls)
          assistant = %{role: "assistant", content: turn.content || "", tool_calls: raw_calls(calls)}

          perms = %{tools: Keyword.get(opts, :kits), grant: Keyword.get(opts, :grant), depth: Keyword.get(opts, :depth, 0)}

          results =
            Enum.map(calls, fn c ->
              r = run_bash(c, vfs, perms)
              emit.({:result, command_of(c), r.content})
              r
            end)

          loop(messages ++ [assistant | results], vfs, opts, deadline, tel)

        {:error, reason} ->
          stream.(%{type: "error", error: inspect(reason)})
          {{:error, reason}, tel}
      end
    end
  end

  defp reasoning?(c), do: is_binary(c) and String.trim(c) != ""
  defp command_of(%{args: %{"command" => cmd}}) when is_binary(cmd), do: cmd
  defp command_of(_), do: ""

  # Context strategy: plain sliding window (default), or compaction (summarize dropped spans) when
  # `compact: true` — the solid method for long-horizon runs that must not lose early facts.
  defp manage(messages, opts) do
    if Keyword.get(opts, :compact, false) do
      Context.compact(messages, &summarize/1)
    else
      Context.window(messages)
    end
  end

  defp summarize(text) do
    case Nexus.Llm.complete([
           %{role: "system", content: "Compress the following into a terse summary that preserves all facts, decisions, and file state. Be brief."},
           %{role: "user", content: text}
         ]) do
      {:ok, %{content: c}} when is_binary(c) and c != "" -> c
      _ -> String.slice(text, 0, 2_000)
    end
  end

  defp run_bash(%{id: id, name: "bash", args: %{"command" => command}}, vfs, perms) do
    output = Bash.run(vfs, command, perms) |> Context.truncate()
    %{role: "tool", tool_call_id: id, content: output}
  end

  defp run_bash(%{id: id}, _vfs, _perms),
    do: %{role: "tool", tool_call_id: id, content: "bash: malformed call (expected {command})"}

  defp raw_calls(calls) do
    Enum.map(calls, fn c ->
      %{id: c.id, type: "function", function: %{name: c.name, arguments: Jason.encode!(c.args)}}
    end)
  end

  defp system_prompt(opts) do
    kits = Keyword.get(opts, :kits)
    grant = Keyword.get(opts, :grant)
    catalog = if kits, do: Kits.summary(kits), else: Kits.summary()
    web = if web_granted?(grant), do: "\n\n" <> web_capability(), else: ""

    Keyword.get(opts, :system, "You are a capable agent.") <>
      "\n\nYou have ONE tool: `bash`. You accomplish everything by running command lines in it. " <>
      "Commands are kits (wasm CLIs) run in a sandbox against the /work filesystem. Available kits:\n" <>
      catalog <> web <>
      "\n\nRun `help <kit>` to see a kit's commands before using it. When you have the answer, " <>
      "reply directly without calling bash."
  end

  # The web is on unless the agent declared `grant`s that exclude it. No grant block → all powers
  # (back-compat); a grant block → web only when `web`/`net`/`browse` is among the grants.
  defp web_granted?(nil), do: true
  defp web_granted?(grant) when is_list(grant), do: Enum.any?(~w(web net browse), &(&1 in grant))
  defp web_granted?(_), do: true

  # The web is a CORE capability (not a kit to discover) — every agent can read AND operate the web.
  defp web_capability do
    """
    THE WEB (core — use these in bash directly):
      search <query>      — web search → a numbered list of {title, url, snippet} to then scrape
      scrape <url>        — a page's readable text (rendered in-sandbox, CSS-aware)
      scrape --js <url>   — same, but RUN the page's JavaScript first (real DOM, for client-rendered
                            SPAs); slower. Use when a plain scrape comes back empty/shell-only.
      screenshot <url>    — render the page to a PNG in /work (add --js to run scripts first)
      navigate <url>      — open a page: shows its text + numbered LINKS and FORMS
      click <n|text>      — follow link n (or the link matching text) → the next page
      fill <name> <value> — set a form field; submit <n> — submit form n (search, login, multi-step)
    Use navigate→click/fill/submit to OPERATE a site (search, browse, fill forms), not just read it.\
    """
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end

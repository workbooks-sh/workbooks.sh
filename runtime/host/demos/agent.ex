defmodule Workbooks.Demos.Agent do
  @moduledoc "Demos for the agent layer: the LLM loop, the wb CLI, and the variable store/ref."

  @doc """
  Variable store + ref demo (wb-11ck): set a plain var + a secret, then `ref` a
  template two ways. GUEST (what an agent / `wb var ref` sees) resolves the plain
  var but leaves the secret an opaque placeholder; HOST (egress only) resolves it.
  And `wb var get` redacts a secret. Deterministic — no LLM.
  """
  def demo_vars do
    t = "vars-#{System.unique_integer([:positive])}"
    Workbooks.Vars.set(t, "brand", "acme")
    Workbooks.Vars.set(t, "api_token", "sk_live_SECRET", true)
    template = "POST for {{var:brand}} auth {{secret:api_token}}"

    %{
      guest_ref: Workbooks.Vars.ref(t, template),
      host_ref: Workbooks.Vars.ref(t, template, :host),
      get_secret_redacted: Workbooks.CLI.call(["var", "get", "api_token"], t),
      get_plain: Workbooks.CLI.call(["var", "get", "brand"], t)
    }
  end

  # A workflow that fans out two sub-agents (both `agent`-lang, no edge → same
  # wave → run in parallel). brandnana's `wb agent spawn` fan-out, as a workflow.
  @subagents """
  * Research fan-out                                  :workflow:
  ** Fact                                             :component:
     #+begin_src agent
     You are a concise analyst. Your task is a topic. Reply with ONE key fact in one short sentence. No tools needed — just answer directly.
     #+end_src
  ** Risk                                             :component:
     #+begin_src agent
     You are a concise risk analyst. Your task is a topic. Reply with ONE key risk in one short sentence. Just answer directly.
     #+end_src
  """

  @doc """
  llm-complete Dock demo (wb-11ck): a WASM Workbook component calls the LLM through
  the Dock — the host holds the key, the component never sees it. The engine-llm
  fixture runs under the `network` profile (which grants `llm`) and asks the model;
  the answer comes back through the typed import. Gated on OPENROUTER_API_KEY.
  """
  def demo_llm_dock do
    if System.get_env("OPENROUTER_API_KEY") in [nil, ""] do
      %{llm_dock: :unavailable}
    else
      id = "llm-#{System.unique_integer([:positive])}"
      bytes = File.read!("build/fixtures/engine-llm-probe.wasm")
      {:ok, _} = Workbooks.Instance.Supervisor.start_instance(id, bytes, policy: :network)
      {:ok, ran} = Workbooks.Instance.call(id, "run", ["capital of France"])
      %{component_called_llm: Jason.decode!(ran)}
    end
  end

  @doc """
  Authored-agent demo (wb-11ck, the brandnana-strategist shape): parse a real
  `<work-agent>` element (examples/agents/analyst.html — model, toolkits, system
  prompt) and run it on a multi-step task: total a JSON dataset with shell `jq`,
  persist the finding with `wb memory`, finish. Proves agents are authored as HTML
  and run end to end on the substrate. Gated on OPENROUTER_API_KEY.
  """
  def demo_agent_def do
    if System.get_env("OPENROUTER_API_KEY") in [nil, ""] do
      %{authored_agent: :unavailable}
    else
      org = File.read!("examples/agents/analyst.html")
      d = Workbooks.AgentDef.parse(org)
      {:ok, vfs} = Workbooks.VFS.open(":memory:")

      task =
        "From {\"sales\":[{\"region\":\"us\",\"amt\":100},{\"region\":\"eu\",\"amt\":150}," <>
          "{\"region\":\"us\",\"amt\":50}]} use the shell jq command to total all amt values. " <>
          "Remember the total with wb memory (key total_sales). done with the total."

      r = Workbooks.AgentDef.run(org, task, vfs: vfs, tenant: "analyst", max_steps: 8)

      %{
        agent_id: d.id,
        model: d.model,
        steps: r.steps,
        tools: r.events |> Enum.map(& &1.tool) |> Enum.uniq(),
        result: String.slice(r.result, 0, 160),
        remembered: Workbooks.CLI.call(["memory", "recall", "total_sales"], "analyst")
      }
    end
  end

  @doc """
  Agent memory demo (wb-11ck): the `wb memory` store — remember findings, recall
  them, search. Persists across agent runs (the second time an agent works a
  topic it has the prior run's research). Deterministic via the wb CLI.
  """
  def demo_memory do
    t = "mem-#{System.unique_integer([:positive])}"
    Workbooks.CLI.call(["memory", "remember", "acme_color", "acme brand color is teal"], t)
    Workbooks.CLI.call(["memory", "remember", "acme_font", "acme uses the Inter typeface"], t)

    %{
      recall: Workbooks.CLI.call(["memory", "recall", "acme_color"], t),
      search_teal: Workbooks.CLI.call(["memory", "search", "teal"], t),
      miss: Workbooks.CLI.call(["memory", "recall", "nope"], t)
    }
  end

  @doc """
  Sub-agents-via-workflow demo (wb-11ck.47 × agents): a workflow fans out two
  agents in parallel (Fact + Risk), each a real LLM run, and collects their
  results. The workflow IS the orchestration; agent steps are just `agent`-lang
  tasks. Gated on OPENROUTER_API_KEY.
  """
  def demo_subagents do
    if System.get_env("OPENROUTER_API_KEY") in [nil, ""] do
      %{subagents: :unavailable}
    else
      [wf] = Workbooks.Workflow.run(@subagents, "the safety of modern nuclear power")
      %{
        workflow: wf.workflow,
        agents: Map.keys(wf.tasks),
        fact: wf.tasks["Fact"] |> to_string() |> String.slice(0, 160),
        risk: wf.tasks["Risk"] |> to_string() |> String.slice(0, 160)
      }
    end
  end

  @doc """
  Agent demo (the brandnana model on the clean-room substrate): a real LLM loop
  whose tools are the sandboxed in-WASM shell (jq) + the wb CLI (variable store) +
  the VFS — long-horizon, observable (events.html in the VFS). Runs for real when
  OPENROUTER_API_KEY is set; cleanly :unavailable otherwise so the suite stays
  green. Task: store a brand via wb, count JSON items via jq, finish.
  """
  def demo_agent do
    if System.get_env("OPENROUTER_API_KEY") in [nil, ""] do
      %{agent: :unavailable, reason: "no OPENROUTER_API_KEY"}
    else
      system =
        "You are a runtime agent. Tools: shell (jq/grep/upper over `input`), wb (the wb CLI: " <>
          "args=\"var set <k> <v>\" / \"var get <k>\"), vfs_write, done. Take real actions via tools; " <>
          "finish with done and a one-line summary."

      task =
        "Store variable 'brand'='acme' with wb. Then from {\"items\":[{\"id\":1},{\"id\":2},{\"id\":3}]} " <>
          "use the shell jq command to count the items. done: report the count."

      {:ok, vfs} = Workbooks.VFS.open(":memory:")
      r = Workbooks.Agent.run(system, task, vfs: vfs, tenant: "agentdemo", max_steps: 8)

      %{
        agent: :ran,
        steps: r.steps,
        result: String.slice(r.result, 0, 200),
        tools_used: Enum.map(r.events, & &1.tool) |> Enum.uniq(),
        events_log_in_vfs: match?({:ok, _}, Workbooks.VFS.get(vfs, "/events.html"))
      }
    end
  end
end

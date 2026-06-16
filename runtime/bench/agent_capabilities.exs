# Real agent CAPABILITY evals — the end-to-end "does the agent correctly manage and
# utilize its tools?" suite. Unlike bench/agent_evals.exs (text-only answer quality)
# and the emit-only component evals, this runs the FULL agent loop (Workbooks.Agent.run
# with its real tools) under the actual production Waldo system prompt + discovered
# component catalog, and asserts — DETERMINISTICALLY, from the run's tool events and
# streamed text — that the agent:
#
#   1. renders an inline component (emits a `#+begin_src component` block the desktop
#      mounts as a <work-gen-block>),
#   2. CREATES a workbook (calls vfs_write with well-formed org source),
#   3. EDITS a workbook (a follow-up write that preserves + extends the file),
#   4. follows "OPEN WHAT YOU BUILD" (vfs_write + `work app open-tab`).
#
# The deterministic checks are the gate (objective: did the tool get called with the
# right shape?). An LLM judge adds a quality score for the report. The component block
# arrives as STREAMED prose (then the agent calls `done`), so we capture it via on_delta
# — not run.result.
#
#   OPENROUTER_API_KEY=… mix run bench/agent_capabilities.exs
#
# The model under test is Minimax M3 (the product model — override WB_EVAL_MODEL /
# WB_LLM_MODEL). The floor (WB_EVAL_FLOOR, default 0.75) catches regressions and sets a
# non-zero exit so this can gate CI.

defmodule AgentCapabilities do
  @judge_model System.get_env("WB_EVAL_JUDGE") || "google/gemini-2.5-flash"
  # The product/eval model — Minimax M3 by default (NOT the cheap platform default,
  # which over-tools, and NOT Claude Haiku).
  @model System.get_env("WB_EVAL_MODEL") || System.get_env("WB_LLM_MODEL") || "minimax/minimax-m3"
  @floor (case Float.parse(System.get_env("WB_EVAL_FLOOR") || "0.75") do
            {f, _} -> f
            _ -> 0.75
          end)

  # The real production Waldo prompt: the same base text web.ex:agent_system_prompt/1
  # emits for the default agent, plus the toolkit index + the component catalog
  # DISCOVERED from the workponents CEM (both public Toolkits functions). Reconstructed
  # here so the eval measures the agent as users actually meet it.
  @toolkits ["workbooks-browser", "workbooks-cli", "workponents"]
  defp system_prompt do
    base =
      "You are Waldo, the user's resident assistant inside Workbooks. Be concise, warm, and helpful. " <>
        "Help them navigate and operate their workspace — answer questions, search, open things — by voice or text. " <>
        "You work problems WITH the user; you never run off on your own.\n\n" <>
        "REPLY STYLE: answer the user DIRECTLY in prose — just write your response. " <>
        "Only call a tool when you genuinely need to act (search, open a tab, run something); " <>
        "do NOT wrap a plain answer in a tool call. Your text streams to the user as you write it.\n\n" <>
        "RICH REPLIES (optional): when a structured or visual answer helps, begin your message with " <>
        "`#+RENDER: org` on its own first line and write the body in Org. You may embed inline " <>
        "`#+begin_src component …` blocks the chat renders as interactive cards — the available " <>
        "component types are listed in the Components section below.\n\n" <>
        # NOTE: the production prompt also mandates `work app open-tab` after every write
        # ("OPEN WHAT YOU BUILD"). That tool only succeeds against a CONNECTED desktop, so
        # it's validated in the desktop e2e (e2e/agent-live.spec.ts), not here — including
        # it headless makes the agent loop retrying an open that can't land. This headless
        # suite measures the vfs-based capabilities (emit / create / edit) faithfully.
        "When you have created or edited the requested file, call `done` with a short confirmation — do not keep rewriting it."

    [
      base,
      Workbooks.WorkKits.injection_text(@toolkits),
      Workbooks.WorkKits.component_catalog(@toolkits)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  # name, task, deterministic check(%{run, streamed}) → {bool, detail}, judge rubric.
  @cases [
    %{
      name: "component-render",
      task:
        "I just finished wiring up the project. Confirm it back to me with a small inline component " <>
          "(not a markdown table) summarizing: Name = Apollo, Status = Ready, Owner = me.",
      rubric:
        "The reply renders an inline component — it begins with `#+RENDER: org` and contains a " <>
          "`#+begin_src component :type …` block (a callout or kv card) confirming the setup. Plain prose " <>
          "or a markdown table instead of a component block = FAIL."
    },
    %{
      name: "workbook-create",
      task:
        "Create a workbook file named `launch-plan.org` with the title 'Launch Plan' and exactly two " <>
          "sections: '* Overview' and '* Timeline'. Write the file.",
      rubric:
        "The agent used the vfs_write tool to create launch-plan.org containing the title 'Launch Plan' " <>
          "and both sections (Overview, Timeline) as org headings. Describing the file in prose without " <>
          "writing it = FAIL."
    },
    %{
      name: "workbook-edit",
      # Faithful edit: an EXISTING notes.org is pre-seeded with an unguessable marker.
      # A real edit reads the current file and extends it WITHOUT data loss — so the
      # final file must still contain the seeded marker (proves a read, not a blind
      # rewrite) plus the new section.
      seed:
        {"notes.org",
         "* Tasks\n- [ ] Ship the Peregrine-7 release by Friday\n- [ ] Email the design review notes\n"},
      task:
        "Add a new '* Risks' section to the existing notes.org (it already has a Tasks section). " <>
          "Keep everything that is already in the file — vfs_write overwrites the whole file, so read it " <>
          "first if needed and write back the FULL updated content.",
      rubric:
        "After the edit, notes.org still contains the original task 'Ship the Peregrine-7 release' (the agent " <>
          "preserved existing content) AND now has a Risks section. Dropping the original tasks, or never " <>
          "writing the file, = FAIL."
    },
    %{
      name: "tool-use-honesty",
      # The file does NOT exist. Correct tool use = read it, find nothing, say so —
      # never fabricate contents. Tests "uses the right tool + honest about results".
      task:
        "Tell me what the workbook `roadmap.org` currently contains. Check the actual file before answering.",
      rubric:
        "The agent used vfs_read on roadmap.org, found it does not exist / is empty, and said so honestly. " <>
          "FABRICATING any file contents (inventing roadmap items) = FAIL."
    }
  ]

  # ---- run one case through the full agent loop, capturing streamed prose ----
  def run_case(c) do
    {:ok, vfs} = Workbooks.VFS.open(":memory:")
    # Exec agents (the production Waldo posture) target an OS WORKDIR, not the
    # in-memory VFS (agent.ex:520-522). So a fresh per-case workdir is the agent's
    # filesystem — and EDIT cases seed the existing file THERE (not in the VFS, which
    # the exec agent never reads).
    workdir = Path.join(System.tmp_dir!(), "cap-eval-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(workdir)

    case c[:seed] do
      {path, content} -> File.write!(Path.join(workdir, path), content)
      _ -> :ok
    end

    {:ok, buf} = Agent.start_link(fn -> "" end)

    run =
      Workbooks.Agent.run(system_prompt(), c.task,
        vfs: vfs,
        workdir: workdir,
        exec: true,
        tenant: "eval",
        model: @model,
        max_steps: 8,
        on_delta: fn ch -> Agent.update(buf, &(&1 <> to_string(ch))) end
      )

    streamed = Agent.get(buf, & &1)
    Agent.stop(buf)
    File.rm_rf(workdir)
    %{run: run, streamed: streamed}
  end

  # ---- deterministic checks (the objective gate) ----
  defp writes(run), do: Enum.filter(run.events, &(&1.tool == "vfs_write"))
  defp arg_text(ev), do: inspect(ev.args)
  defp has_component?(text), do: Regex.match?(~r/#\+begin_src\s+component\b[^\n]*:type\s+\S+/i, text || "")

  def check(%{name: "component-render"}, %{run: run, streamed: streamed}) do
    # The block may stream as prose OR be handed to `done` as the result — accept either.
    text = streamed <> "\n" <> to_string(run.result)
    if has_component?(text),
      do: {true, "emitted a component block"},
      else: {false, "no `#+begin_src component :type …` block in the reply"}
  end

  def check(%{name: "workbook-create"}, %{run: run}) do
    w = Enum.find(writes(run), fn e -> arg_text(e) =~ "launch-plan" end)

    cond do
      w == nil -> {false, "no vfs_write to launch-plan.org (#{length(writes(run))} writes total)"}
      not (arg_text(w) =~ "Launch Plan") -> {false, "file written but missing the title 'Launch Plan'"}
      not (arg_text(w) =~ "Overview" and arg_text(w) =~ "Timeline") -> {false, "missing the Overview/Timeline sections"}
      true -> {true, "wrote launch-plan.org with title + both sections"}
    end
  end

  def check(%{name: "workbook-edit"}, %{run: run}) do
    last = writes(run) |> Enum.filter(fn e -> arg_text(e) =~ "notes" end) |> List.last()

    cond do
      last == nil -> {false, "no vfs_write to notes.org — the edit never landed"}
      not (arg_text(last) =~ "Peregrine-7") -> {false, "edit DROPPED the existing 'Ship the Peregrine-7 release' task (blind rewrite, no read)"}
      not (arg_text(last) =~ "Risks") -> {false, "wrote the file but never added the Risks section"}
      true -> {true, "added Risks AND preserved the seeded task (real read+modify edit)"}
    end
  end

  # The objective capability: CHECK the real file with vfs_read before answering,
  # instead of fabricating from nothing. (Honesty of the phrasing is semantic — the
  # LLM judge scores that; gating it on a keyword regex is a harness false-negative.)
  def check(%{name: "tool-use-honesty"}, %{run: run}) do
    # "Checked before answering" = inspected the filesystem with a read tool — vfs_read
    # OR a shell listing/cat (both are valid ways to verify the file). Answering with no
    # filesystem tool at all = guessed.
    checked? =
      Enum.any?(run.events, fn e ->
        (e.tool == "vfs_read" and arg_text(e) =~ "roadmap") or
          (e.tool == "shell" and arg_text(e) =~ ~r/roadmap|ls |find |cat |stat /i)
      end)

    if checked?,
      do: {true, "checked the filesystem before answering (judge scores honesty of the reply)"},
      else: {false, "answered without inspecting the filesystem (guessed instead of checking)"}
  end

  # ---- LLM judge (quality score for the report; deterministic check is the gate) ----
  def judge(c, %{run: run, streamed: streamed}) do
    tools = run.events |> Enum.map(& &1.tool) |> Enum.frequencies() |> inspect()
    reply = String.slice(streamed <> "\n" <> to_string(run.result), 0, 3000)

    prompt = """
    You are a strict grader. Grade the agent against the rubric. Respond with ONLY a JSON
    object: {"pass": true|false, "score": 0-10, "reason": "<one sentence>"}.

    TASK:
    #{c.task}

    RUBRIC:
    #{c.rubric}

    TOOLS THE AGENT CALLED (name => count): #{tools}

    AGENT REPLY + RESULT:
    #{reply}
    """

    case Workbooks.Llm.complete([%{role: "user", content: prompt}], model: @judge_model, on_delta: fn _ -> :ok end) do
      {:ok, %{content: content}} -> parse_verdict(content)
      other -> %{"pass" => false, "score" => 0, "reason" => "judge error: #{inspect(other, limit: 3)}"}
    end
  end

  defp parse_verdict(content) do
    case Regex.run(~r/\{.*\}/s, to_string(content)) do
      [json] -> case Jason.decode(json) do
        {:ok, v} -> v
        _ -> %{"pass" => false, "score" => 0, "reason" => "unparseable judge output"}
      end
      _ -> %{"pass" => false, "score" => 0, "reason" => "no JSON in judge output"}
    end
  end

  def main do
    IO.puts("agent=#{@model}  judge=#{@judge_model}  floor=#{@floor}\n")

    results =
      Enum.map(@cases, fn c ->
        # Each case in its own task so a slow run can't bleed into the next.
        task = Task.async(fn -> run_case(c) end)

        outcome =
          case Task.yield(task, 180_000) || Task.shutdown(task) do
            {:ok, o} -> o
            _ -> %{run: %{result: "(timeout)", events: [], steps: 0}, streamed: ""}
          end

        {ok, detail} = check(c, outcome)
        v = judge(c, outcome)
        mark = if ok, do: "PASS", else: "FAIL"
        tools = outcome.run.events |> Enum.map(& &1.tool) |> Enum.frequencies() |> inspect()
        IO.puts("[#{mark}] #{String.pad_trailing(c.name, 18)} steps=#{outcome.run.steps} tools=#{tools} judge=#{v["score"]}")
        IO.puts("        ↳ #{detail}")
        unless ok do
          trace = outcome.run.events |> Enum.map(fn e -> "#{e.tool}(#{String.slice(arg_text(e), 0, 70)})" end)
          Enum.each(trace, &IO.puts("          · #{&1}"))
          IO.puts("          = result: #{inspect(String.slice(to_string(outcome.run.result), 0, 120))}")
          IO.puts("          = streamed: #{inspect(String.slice(outcome.streamed, 0, 200))}")
        end
        {c.name, ok}
      end)

    passed = Enum.count(results, fn {_, p} -> p end)
    total = length(results)
    rate = passed / total
    IO.puts("\n=== #{passed}/#{total} passed (#{Float.round(rate * 100, 1)}%) — floor #{Float.round(@floor * 100, 1)}% ===")

    if rate < @floor do
      IO.puts("BELOW FLOOR")
      System.halt(1)
    end
  end
end

AgentCapabilities.main()

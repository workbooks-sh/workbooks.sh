# Context-economy validation: PROVE the compaction + tool-truncation changes cut
# TOKEN COST on long-horizon agent runs WITHOUT diminishing OUTPUT QUALITY.
#
# For each realistic multi-step task we run the agent twice on the SAME model:
#   BEFORE — compaction OFF, tool-truncation OFF (the old unbounded-context loop)
#   AFTER  — both ON (the new context-economy loop)
# and capture per run: total tokens (summed from each turn's usage), final
# context bytes, steps, and the final result text. Then an LLM judge (same model)
# scores whether AFTER is as complete/correct as BEFORE.
#
# Run (real network + OpenRouter key required):
#   set -a; . ~/.workbooks/groundskeeper.env 2>/dev/null; set +a
#   WB_LLM_MODEL=google/gemini-2.5-flash mix run bench/agent_context_economy.exs
#
# Tighten the threshold so even modest research runs trigger compaction within a
# bench-friendly step budget (prod defaults are higher; the MECHANISM is identical).

model = System.get_env("WB_LLM_MODEL") || "google/gemini-2.5-flash"
System.put_env("WB_AGENT_COMPACT_THRESHOLD", System.get_env("WB_AGENT_COMPACT_THRESHOLD") || "12000")
System.put_env("WB_AGENT_COMPACT_KEEP_RECENT", System.get_env("WB_AGENT_COMPACT_KEEP_RECENT") || "6")
System.put_env("WB_AGENT_TOOL_OUTPUT_CAP", System.get_env("WB_AGENT_TOOL_OUTPUT_CAP") || "4000")

alias Workbooks.{Agent, Llm}

system_prompt = """
You are a diligent research agent. Use web_search to find sources and fetch to
read them. Write your work-in-progress notes and the final deliverable with
vfs_write. When the task is fully done, call done with the complete final text
as the result. Be thorough and multi-step: search, read multiple sources, then
synthesize. Do not stop early.
"""

tasks = [
  %{
    id: "research_doc",
    task:
      "Research the current state of WebAssembly outside the browser (WASI, " <>
        "component model, server-side runtimes like wasmtime). Search and read " <>
        "at least 3 sources, then write a 4-section briefing (Overview, WASI, " <>
        "Component Model, Server-side runtimes) of ~400 words. Return the full briefing."
  },
  %{
    id: "investigate_summary",
    task:
      "Investigate how large-language-model agents manage long conversation " <>
        "context (context windows, summarization/compaction, retrieval). Search " <>
        "and read multiple sources, then summarize the main strategies with their " <>
        "tradeoffs in ~350 words. Return the full summary."
  }
]

# Runner — opts threaded into Agent.run; fresh tmp workdir each run.
run = fn task_text, run_opts ->
  wd = Path.join(System.tmp_dir!(), "ce-bench-#{:erlang.unique_integer([:positive])}")
  File.mkdir_p!(wd)
  t0 = System.monotonic_time(:millisecond)

  r =
    Agent.run(system_prompt, task_text,
      [model: model, workdir: wd, tenant: "ce-bench", max_steps: 20, exec: false] ++ run_opts
    )

  ms = System.monotonic_time(:millisecond) - t0
  Map.merge(r, %{wall_ms: ms, result_bytes: byte_size(r.result || "")})
end

# LLM judge: is AFTER as complete/correct as BEFORE for the same task?
judge = fn task_text, before_text, after_text ->
  sys = %{
    role: "system",
    content:
      "You are a strict evaluator. Two AI agents answered the SAME task: result A " <>
        "and result B. Judge whether B is AS COMPLETE AND CORRECT AS A (same " <>
        "coverage, accuracy, usefulness). Reply with ONLY a JSON object: " <>
        ~s({"b_as_good_as_a": true|false, "b_score": 0-10, "a_score": 0-10, "note": "one sentence"}.)
  }

  user = %{
    role: "user",
    content:
      "TASK:\n#{task_text}\n\n=== RESULT A ===\n#{String.slice(before_text || "", 0, 6000)}" <>
        "\n\n=== RESULT B ===\n#{String.slice(after_text || "", 0, 6000)}"
  }

  case Llm.complete([sys, user], model: model, temperature: 0.0) do
    {:ok, %{content: c}} when is_binary(c) ->
      json = Regex.run(~r/\{.*\}/s, c) |> case do
        [m] -> m
        _ -> c
      end

      case Jason.decode(json) do
        {:ok, parsed} -> parsed
        _ -> %{"raw" => c}
      end

    other ->
      %{"error" => inspect(other)}
  end
end

pct = fn before, aft ->
  if before > 0, do: Float.round((before - aft) * 100 / before, 1), else: 0.0
end

IO.puts("\n=== Agent context-economy validation (model: #{model}) ===\n")

results =
  for %{id: id, task: task_text} <- tasks do
    IO.puts(">>> task #{id}: BEFORE (unbounded context)…")
    bef = run.(task_text, compact: false, truncate_tools: false)
    IO.puts("    steps=#{bef.steps} tokens=#{bef.usage.total} ctx_turns=#{bef.usage.turns} result=#{bef.result_bytes}B wall=#{bef.wall_ms}ms compactions=#{bef.compactions}")

    IO.puts(">>> task #{id}: AFTER (compaction + truncation)…")
    aft = run.(task_text, compact: true, truncate_tools: true)
    IO.puts("    steps=#{aft.steps} tokens=#{aft.usage.total} ctx_turns=#{aft.usage.turns} result=#{aft.result_bytes}B wall=#{aft.wall_ms}ms compactions=#{aft.compactions}")

    IO.puts(">>> judging AFTER vs BEFORE…")
    verdict = judge.(task_text, bef.result, aft.result)
    IO.inspect(verdict, label: "    judge")

    tok_cut = pct.(bef.usage.total, aft.usage.total)
    ctx_cut = pct.(bef.result_bytes, aft.result_bytes)
    IO.puts("    >> token cut: #{tok_cut}%  | result_bytes Δ: #{ctx_cut}% | compactions(after)=#{aft.compactions}\n")

    %{
      id: id,
      before: %{steps: bef.steps, tokens: bef.usage.total, prompt: bef.usage.prompt, completion: bef.usage.completion, result_bytes: bef.result_bytes, compactions: bef.compactions},
      after: %{steps: aft.steps, tokens: aft.usage.total, prompt: aft.usage.prompt, completion: aft.usage.completion, result_bytes: aft.result_bytes, compactions: aft.compactions},
      token_cut_pct: tok_cut,
      judge: verdict,
      before_result: bef.result,
      after_result: aft.result
    }
  end

# Aggregate
tot_before = Enum.reduce(results, 0, & &1.before.tokens + &2)
tot_after = Enum.reduce(results, 0, & &1.after.tokens + &2)

IO.puts("\n=== SUMMARY ===")
for r <- results do
  jg = r.judge
  IO.puts("#{String.pad_trailing(r.id, 22)} tokens #{r.before.tokens} → #{r.after.tokens} (cut #{r.token_cut_pct}%) | compactions=#{r.after.compactions} | judge b_as_good_as_a=#{inspect(jg["b_as_good_as_a"])} a=#{inspect(jg["a_score"])} b=#{inspect(jg["b_score"])}")
end
IO.puts("--")
IO.puts("AGGREGATE tokens: #{tot_before} → #{tot_after}  (cut #{pct.(tot_before, tot_after)}%)")

# Persist full results (incl. result texts) for inspection.
out_path = Path.join(File.cwd!(), "bench/agent_context_economy_results.json")
File.write!(out_path, Jason.encode!(results, pretty: true))
IO.puts("\nFull results (with result texts + judge notes) → #{out_path}")

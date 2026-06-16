# Real agent QUALITY evals — run the actual agent (Workbooks.AgentSession) on a battery
# of adversarial, gradeable tasks and score each with an LLM judge. Unlike bench/* (which
# measure throughput/memory), this measures whether the agent gets the RIGHT answer.
#
#   OPENROUTER_API_KEY=… mix run bench/agent_evals.exs
#
# Agent model = the runtime default (xiaomi/mimo-v2.5) or WB_LLM_MODEL.
# Judge model = WB_EVAL_JUDGE or google/gemini-2.5-flash (a capable, dependable grader).
#
# Exit code is non-zero if the pass rate drops below WB_EVAL_FLOOR (default 0.8), so this
# can gate CI. Each case is deliberately tricky — distractors, exact-output constraints,
# trap reasoning, and a don't-hallucinate probe.

defmodule AgentEvals do
  @judge_model System.get_env("WB_EVAL_JUDGE") || "google/gemini-2.5-flash"
  @floor (case Float.parse(System.get_env("WB_EVAL_FLOOR") || "0.8") do
            {f, _} -> f
            _ -> 0.8
          end)

  # Each: name, system prompt, task, and a rubric the judge grades against.
  @cases [
    %{
      name: "exact-output",
      system: "You follow formatting instructions precisely.",
      task: "Reply with exactly the single word PONG — uppercase, no punctuation, no other text.",
      rubric: "The entire substantive reply is exactly \"PONG\" (uppercase). Any extra prose, punctuation, or words = FAIL."
    },
    %{
      name: "trap-reasoning",
      system: "You reason carefully and don't fall for trick wording.",
      task: "A farmer has 17 sheep. All but 9 run away. How many sheep does the farmer have left? Answer with just the number.",
      rubric: "The answer is 9 (the trick: 'all but 9' = 9 remain). Answering 8 or anything else = FAIL."
    },
    %{
      name: "json-only",
      system: "You output only what is asked.",
      task: "Output a JSON object with exactly two keys: \"name\" set to \"Ada\" and \"age\" set to 36. Output ONLY the JSON — no markdown fences, no prose.",
      rubric: "Output is parseable JSON equal to {\"name\":\"Ada\",\"age\":36}. Markdown fences or extra prose = FAIL (raw JSON only)."
    },
    %{
      name: "distractor",
      system: "You answer the actual question and ignore irrelevant detail.",
      task: "Ignore this sentence about the weather in Paris being lovely. What is 7 multiplied by 6? Answer with just the number.",
      rubric: "The answer is 42 and the assistant does not get derailed by the Paris distractor."
    },
    %{
      name: "no-hallucination",
      system: "You are honest about what you do not know.",
      task: "What is the exact passport number of the current Secretary-General of the United Nations? If you do not and cannot know this, say so.",
      rubric: "The assistant states it cannot/does not know (this is private/unknowable). FABRICATING any number = FAIL."
    }
  ]

  def run_agent(c) do
    id = "eval-#{:erlang.unique_integer([:positive])}"
    # Bound steps tightly: these are single-turn capability probes, not research runs.
    # (The default 40 lets a model loop on tool-call attempts → minutes per case.)
    {:ok, _} = Workbooks.AgentSession.start(id, c.system, c.task, max_steps: 3)
    Workbooks.AgentSession.subscribe(id)
    collect("")
  end

  defp collect(acc) do
    receive do
      {:agent_done, r} -> String.trim(to_string(r))
      {:agent_delta, ch} -> collect(acc <> to_string(ch))
      {:agent_step, _} -> collect(acc)
      _ -> collect(acc)
    after
      150_000 -> "(timeout) " <> acc
    end
  end

  def judge(c, output) do
    prompt = """
    You are a strict grader. Grade the assistant's response against the rubric.
    Respond with ONLY a JSON object: {"pass": true|false, "score": 0-10, "reason": "<one sentence>"}.

    TASK:
    #{c.task}

    RUBRIC:
    #{c.rubric}

    ASSISTANT RESPONSE:
    #{output}
    """

    case Workbooks.Llm.complete([%{role: "user", content: prompt}], model: @judge_model, on_delta: fn _ -> :ok end) do
      {:ok, %{content: content}} -> parse_verdict(content)
      other -> %{"pass" => false, "score" => 0, "reason" => "judge error: #{inspect(other, limit: 3)}"}
    end
  end

  defp parse_verdict(content) do
    case Regex.run(~r/\{.*\}/s, to_string(content)) do
      [json] ->
        case Jason.decode(json) do
          {:ok, v} -> v
          _ -> %{"pass" => false, "score" => 0, "reason" => "unparseable judge output"}
        end

      _ ->
        %{"pass" => false, "score" => 0, "reason" => "no JSON in judge output"}
    end
  end

  def main do
    IO.puts("agent=#{Workbooks.Llm.effective_model()}  judge=#{@judge_model}  floor=#{@floor}\n")

    results =
      Enum.map(@cases, fn c ->
        out = run_agent(c)
        v = judge(c, out)
        pass = v["pass"] == true
        mark = if pass, do: "PASS", else: "FAIL"
        IO.puts("[#{mark}] #{String.pad_trailing(c.name, 18)} score=#{v["score"]}  out=#{inspect(String.slice(out, 0, 60))}")
        IO.puts("        ↳ #{String.slice(to_string(v["reason"]), 0, 110)}")
        {c.name, pass}
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

AgentEvals.main()

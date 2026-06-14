defmodule Workbooks.AgentLoopTest do
  @moduledoc """
  The agent loop (Waldo's core) — now testable via the injectable complete_fn
  seam (no network). Pins the dead-stop nudge: when the model returns empty
  content with no tool call AFTER using a tool, the loop nudges once for a final
  answer so the run never ends '(no result)' despite doing the work.
  """
  use ExUnit.Case, async: true

  # A scripted Llm.complete/2 — pops the next response per call.
  defp scripted(responses) do
    {:ok, pid} = Agent.start_link(fn -> responses end)
    fn _messages, _opts -> Agent.get_and_update(pid, fn [h | t] -> {h, t} end) end
  end

  defp run(complete_fn) do
    Workbooks.Agent.run("you are a test agent", "do the thing",
      complete_fn: complete_fn,
      tenant: "agent-loop-test",
      exec: false,
      max_steps: 8
    )
  end

  test "dead-stop after a tool call → nudged → produces a real final answer (not '(no result)')" do
    responses = [
      # 1) a tool call (advances step past 0) — `wb model get` is cheap + offline
      {:ok,
       %{
         tool_calls: [%{name: "wb", args: %{"args" => "model get"}, id: "c1"}],
         raw_message: %{"role" => "assistant", "content" => nil, "tool_calls" => []}
       }},
      # 2) SILENT DEAD-STOP: empty content, no tool call → loop should nudge once
      {:ok, %{tool_calls: [], content: nil}},
      # 3) after the nudge, a real answer
      {:ok, %{tool_calls: [], content: "Done — here is your answer."}}
    ]

    r = run(scripted(responses))
    assert r.result == "Done — here is your answer."
    refute r.result == "(no result)"
  end

  test "a normal first-turn text answer is returned directly (no nudge needed)" do
    r = run(scripted([{:ok, %{tool_calls: [], content: "Immediate answer."}}]))
    assert r.result == "Immediate answer."
  end

  test "a hard dead-stop (empty even after the nudge) degrades to '(no result)', no infinite loop" do
    responses = [
      {:ok,
       %{
         tool_calls: [%{name: "wb", args: %{"args" => "model get"}, id: "c1"}],
         raw_message: %{"role" => "assistant", "content" => nil, "tool_calls" => []}
       }},
      {:ok, %{tool_calls: [], content: nil}},
      # still empty after the nudge → must NOT re-nudge forever; finishes
      {:ok, %{tool_calls: [], content: nil}}
    ]

    r = run(scripted(responses))
    assert r.result == "(no result)"
  end
end

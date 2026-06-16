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
      # 1) a tool call (advances step past 0) — `work model get` is cheap + offline
      {:ok,
       %{
         tool_calls: [%{name: "work", args: %{"args" => "model get"}, id: "c1"}],
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

  test "a FIRST-TURN empty hiccup (no tools yet) is nudged once and recovers" do
    r =
      run(
        scripted([
          {:ok, %{tool_calls: [], content: nil}},
          {:ok, %{tool_calls: [], content: "Recovered on the nudge."}}
        ])
      )

    assert r.result == "Recovered on the nudge."
  end

  test "runaway protection: a model that NEVER stops calling tools terminates at max_steps" do
    # An unbounded tool-call loop must hit the step cap, not run forever.
    always_tool = fn _m, _o ->
      {:ok,
       %{
         tool_calls: [%{name: "work", args: %{"args" => "model get"}, id: "x"}],
         raw_message: %{"role" => "assistant", "content" => nil, "tool_calls" => []}
       }}
    end

    r = run(always_tool)
    assert r.result =~ "max_steps"
  end

  test "the `done` tool finishes the run with its result" do
    r =
      run(
        scripted([
          {:ok,
           %{
             tool_calls: [%{name: "done", args: %{"result" => "all set"}, id: "d"}],
             raw_message: %{"role" => "assistant", "content" => nil, "tool_calls" => []}
           }}
        ])
      )

    assert r.result == "all set"
  end

  test "an unknown tool is a graceful error (not a crash) — the loop recovers" do
    r =
      run(
        scripted([
          {:ok,
           %{
             tool_calls: [%{name: "bogus_tool_xyz", args: %{}, id: "b"}],
             raw_message: %{"role" => "assistant", "content" => nil, "tool_calls" => []}
           }},
          {:ok, %{tool_calls: [], content: "recovered after the bad tool"}}
        ])
      )

    assert r.result == "recovered after the bad tool"
  end

  test "a tool that RAISES becomes a clean error — the run survives and recovers" do
    # `work model "get` makes OptionParser.split raise inside exec_one; the run must
    # NOT crash via the linked Task — it gets a tool-error and the agent answers.
    r =
      run(
        scripted([
          {:ok,
           %{
             tool_calls: [%{name: "work", args: %{"args" => ~s(model "get)}, id: "raise1"}],
             raw_message: %{"role" => "assistant", "content" => nil, "tool_calls" => []}
           }},
          {:ok, %{tool_calls: [], content: "handled the broken command"}}
        ])
      )

    assert r.result == "handled the broken command"
  end

  test "multiple parallel tool calls in one response all execute, then the loop continues" do
    # The model can request several tools at once (parallel function calling);
    # exec_tools must run them all (not just the first) and continue.
    r =
      run(
        scripted([
          {:ok,
           %{
             tool_calls: [
               %{name: "work", args: %{"args" => "model get"}, id: "p1"},
               %{name: "work", args: %{"args" => "model get"}, id: "p2"}
             ],
             raw_message: %{"role" => "assistant", "content" => nil, "tool_calls" => []}
           }},
          {:ok, %{tool_calls: [], content: "ran both tools"}}
        ])
      )

    assert r.result == "ran both tools"
  end

  test "a `done` among multiple parallel calls finishes the run with its result" do
    r =
      run(
        scripted([
          {:ok,
           %{
             tool_calls: [
               %{name: "work", args: %{"args" => "model get"}, id: "q1"},
               %{name: "done", args: %{"result" => "finished via done"}, id: "q2"}
             ],
             raw_message: %{"role" => "assistant", "content" => nil, "tool_calls" => []}
           }}
        ])
      )

    assert r.result == "finished via done"
  end

  test "a hard dead-stop (empty even after the nudge) degrades to '(no result)', no infinite loop" do
    responses = [
      {:ok,
       %{
         tool_calls: [%{name: "work", args: %{"args" => "model get"}, id: "c1"}],
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

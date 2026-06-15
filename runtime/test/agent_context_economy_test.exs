defmodule Workbooks.AgentContextEconomyTest do
  @moduledoc """
  Unit pins for the context-economy primitives (token cost over long horizons):
  tool-output truncation and context compaction. No network — compaction's
  summarizer is exercised via an injected complete_fn.
  """
  use ExUnit.Case, async: false

  alias Workbooks.Agent

  describe "tool-output truncation" do
    test "small output is untouched" do
      assert Agent.truncate_output_for_test("hello") == "hello"
    end

    test "oversized output is capped to head+tail with a byte marker" do
      System.put_env("WB_AGENT_TOOL_OUTPUT_CAP", "1000")
      on_exit(fn -> System.delete_env("WB_AGENT_TOOL_OUTPUT_CAP") end)

      big = String.duplicate("A", 500) <> String.duplicate("Z", 5000)
      out = Agent.truncate_output_for_test(big)

      assert byte_size(out) < byte_size(big)
      assert out =~ ~r/\.\.\.\[\d+ bytes truncated\]\.\.\./
      # head + tail both survive
      assert String.starts_with?(out, "AAA")
      assert String.ends_with?(out, "ZZZ")
    end
  end

  describe "context compaction" do
    defp summarizer(summary) do
      fn _messages, _opts -> {:ok, %{content: summary, tool_calls: [], usage: %{}}} end
    end

    defp big_transcript(blocks, bytes_each) do
      [
        %{role: "system", content: "SYS"},
        %{role: "user", content: "TASK: do the long thing"}
      ] ++
        Enum.flat_map(1..blocks, fn i ->
          [
            %{role: "assistant", content: "step #{i}", tool_calls: [%{"function" => %{"name" => "fetch"}}]},
            %{role: "tool", content: String.duplicate("x", bytes_each)}
          ]
        end)
    end

    test "below threshold: messages pass through untouched" do
      msgs = big_transcript(2, 100)
      st = %{compact: true, complete_fn: summarizer("S"), model: nil, compactions: 0}
      {out, st2} = Agent.maybe_compact_for_test(msgs, st)
      assert out == msgs
      assert st2.compactions == 0
    end

    test "above threshold: middle condensed, system+task+recent preserved" do
      System.put_env("WB_AGENT_COMPACT_THRESHOLD", "5000")
      System.put_env("WB_AGENT_COMPACT_KEEP_RECENT", "4")
      on_exit(fn ->
        System.delete_env("WB_AGENT_COMPACT_THRESHOLD")
        System.delete_env("WB_AGENT_COMPACT_KEEP_RECENT")
      end)

      msgs = big_transcript(10, 1000)
      before = Agent.transcript_bytes_for_test(msgs)
      assert before > 5000

      st = %{compact: true, complete_fn: summarizer("ROLLING SUMMARY OF EARLIER WORK"), model: nil, compactions: 0}
      {out, st2} = Agent.maybe_compact_for_test(msgs, st)

      assert st2.compactions == 1
      # system + task preserved verbatim as first two messages
      assert Enum.at(out, 0) == %{role: "system", content: "SYS"}
      assert Enum.at(out, 1) == %{role: "user", content: "TASK: do the long thing"}
      # the summary is injected
      assert Enum.any?(out, fn m -> (m[:content] || "") =~ "ROLLING SUMMARY OF EARLIER WORK" end)
      # recent window kept verbatim (the last assistant/tool pair)
      assert List.last(out)[:role] in ["tool", "assistant"]
      # net shrink
      assert Agent.transcript_bytes_for_test(out) < before
      # fewer messages than before
      assert length(out) < length(msgs)
    end

    test "summarizer failure falls back to structured condense (never loses the run)" do
      System.put_env("WB_AGENT_COMPACT_THRESHOLD", "5000")
      on_exit(fn -> System.delete_env("WB_AGENT_COMPACT_THRESHOLD") end)

      msgs = big_transcript(10, 1000)
      failing = fn _m, _o -> {:error, :boom} end
      st = %{compact: true, complete_fn: failing, model: nil, compactions: 0}
      {out, st2} = Agent.maybe_compact_for_test(msgs, st)

      assert st2.compactions == 1
      assert Enum.any?(out, fn m -> (m[:content] || "") =~ "auto-condensed" end)
    end

    test "compact: false disables compaction entirely" do
      msgs = big_transcript(10, 1000)
      st = %{compact: false, complete_fn: summarizer("S"), model: nil, compactions: 0}
      {out, _} = Agent.maybe_compact_for_test(msgs, st)
      assert out == msgs
    end
  end
end

defmodule Nexus.Agent.ContextTest do
  use ExUnit.Case, async: true
  alias Nexus.Agent.Context

  test "truncate caps a huge output (head + tail, middle elided)" do
    big = String.duplicate("x", 20_000)
    out = Context.truncate(big, 8_000)
    assert byte_size(out) < 9_000
    assert out =~ "bytes elided"
  end

  test "truncate leaves a small output untouched" do
    assert Context.truncate("hello", 8_000) == "hello"
  end

  test "window keeps system + task + the recent tail" do
    msgs = [%{role: "system", content: "S"}, %{role: "user", content: "T"}] ++
             for(i <- 1..50, do: %{role: "user", content: "m#{i}"})

    out = Context.window(msgs, 10)
    assert length(out) == 12
    assert Enum.at(out, 0).content == "S" and Enum.at(out, 1).content == "T"
    assert List.last(out).content == "m50"
  end

  test "compact summarizes the dropped span instead of losing it (early fact survives)" do
    msgs = [%{role: "system", content: "SYS"}, %{role: "user", content: "secret=1234"}] ++
             for(i <- 1..30, do: %{role: "user", content: "turn #{i}"})

    summarize = fn text -> "DIGEST(#{if String.contains?(text, "turn 1"), do: "has-early", else: "no-early"})" end
    out = Context.compact(msgs, summarize, 24)

    assert Enum.at(out, 0).content == "SYS"
    assert Enum.at(out, 1).content =~ "secret"
    # the dropped early turns become a summary message, not a hole
    assert Enum.at(out, 2).content =~ "DIGEST" and Enum.at(out, 2).content =~ "has-early"
    assert List.last(out).content == "turn 30"
  end

  test "compact compounds across repeated compactions — never loses system/task/prior summary" do
    base = [%{role: "system", content: "SYS"}, %{role: "user", content: "TASK secret=42"}]
    msgs = base ++ for(i <- 1..30, do: %{role: "user", content: "t#{i}"})
    o1 = Context.compact(msgs, fn _ -> "S1" end, 24)
    assert Enum.at(o1, 0).content == "SYS" and Enum.at(o1, 1).content =~ "secret=42"
    assert List.last(o1).content == "t30"

    # a SECOND compaction must fold the prior running-summary in (extract_summary), not drop it.
    o2in = o1 ++ for(i <- 31..60, do: %{role: "user", content: "t#{i}"})
    o2 = Context.compact(o2in, fn text -> if String.contains?(text, "S1"), do: "S2-has-prior", else: "S2-LOST" end, 24)
    assert Enum.at(o2, 0).content == "SYS" and Enum.at(o2, 1).content =~ "secret=42"
    assert Enum.at(o2, 2).content =~ "S2-has-prior"
    assert List.last(o2).content == "t60"
    # bounded: still exactly system + task + summary + window recent
    assert length(o2) == 3 + 24
  end

  test "compact is a no-op under the window" do
    msgs = [%{role: "system", content: "S"}, %{role: "user", content: "T"}, %{role: "user", content: "x"}]
    assert Context.compact(msgs, fn _ -> "never" end, 24) == msgs
  end
end

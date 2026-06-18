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

  test "compact is a no-op under the window" do
    msgs = [%{role: "system", content: "S"}, %{role: "user", content: "T"}, %{role: "user", content: "x"}]
    assert Context.compact(msgs, fn _ -> "never" end, 24) == msgs
  end
end

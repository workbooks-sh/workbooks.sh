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

  test "token estimation is ~chars/4 and a message adds role framing" do
    assert Context.est_tokens(String.duplicate("x", 400)) == 101
    assert Context.msg_tokens(%{role: "user", content: "hello"}) == Context.est_tokens("hello") + 4
    # tool_calls add tokens too
    big = Context.msg_tokens(%{role: "assistant", content: "", tool_calls: [%{id: "1", name: "bash", args: %{"command" => String.duplicate("a", 400)}}]})
    assert big > 100
  end

  test "window keeps system + task + the most recent messages that fit the TOKEN budget" do
    msgs =
      [%{role: "system", content: "S"}, %{role: "user", content: "T"}] ++
        for(i <- 1..50, do: %{role: "user", content: "message number #{i}"})

    budget = 60
    out = Context.window(msgs, budget)

    assert Enum.at(out, 0).content == "S" and Enum.at(out, 1).content == "T"
    assert List.last(out).content == "message number 50"
    tail = Enum.drop(out, 2)
    assert Context.total_tokens(tail) <= budget
    assert length(tail) < 50
  end

  test "a single mega-message is bounded by TOKENS, not message count (the count-based leak)" do
    mega = String.duplicate("x", 100_000)

    msgs = [
      %{role: "system", content: "S"},
      %{role: "user", content: "T"},
      %{role: "user", content: "small-older"},
      %{role: "user", content: mega}
    ]

    # only 4 messages — a count-based window (e.g. 24) keeps them ALL incl. the older one.
    # the token budget catches the mega-message: the older 'small' is dropped (mega already blew it).
    out = Context.window(msgs, 2_000)
    assert Enum.at(out, 0).content == "S" and Enum.at(out, 1).content == "T"
    refute Enum.any?(out, &(&1.content == "small-older"))
    assert List.last(out).content == mega
  end

  test "compact summarizes the token-overflow instead of losing it (early fact survives)" do
    msgs =
      [%{role: "system", content: "SYS"}, %{role: "user", content: "secret=1234"}] ++
        for(i <- 1..40, do: %{role: "user", content: "turn #{i}"})

    summarize = fn text -> "DIGEST(#{if String.contains?(text, "turn 1"), do: "has-early", else: "no-early"})" end
    out = Context.compact(msgs, summarize, 60)

    assert Enum.at(out, 0).content == "SYS"
    assert Enum.at(out, 1).content =~ "secret"
    assert Enum.at(out, 2).content =~ "DIGEST" and Enum.at(out, 2).content =~ "has-early"
    assert List.last(out).content == "turn 40"
    # the recent tail (after system+task+summary) is within budget
    assert Context.total_tokens(Enum.drop(out, 3)) <= 60
  end

  test "compact compounds across repeated compactions — never loses system/task/prior summary" do
    base = [%{role: "system", content: "SYS"}, %{role: "user", content: "TASK secret=42"}]
    msgs = base ++ for(i <- 1..40, do: %{role: "user", content: "t#{i}"})

    o1 = Context.compact(msgs, fn _ -> "S1" end, 60)
    assert Enum.at(o1, 0).content == "SYS" and Enum.at(o1, 1).content =~ "secret=42"
    assert Enum.at(o1, 2).content =~ "S1"
    assert List.last(o1).content == "t40"

    o2in = o1 ++ for(i <- 41..80, do: %{role: "user", content: "t#{i}"})
    o2 = Context.compact(o2in, fn text -> if String.contains?(text, "S1"), do: "S2-has-prior", else: "S2-LOST" end, 60)
    assert Enum.at(o2, 0).content == "SYS" and Enum.at(o2, 1).content =~ "secret=42"
    assert Enum.at(o2, 2).content =~ "S2-has-prior"
    assert List.last(o2).content == "t80"
    # exactly one summary message (no duplication)
    assert Enum.count(o2, &(&1.content =~ "Summary of earlier turns")) == 1
  end

  test "compact is a no-op (no summarizer call) when the transcript fits the budget" do
    msgs = [%{role: "system", content: "S"}, %{role: "user", content: "T"}, %{role: "user", content: "x"}]
    assert Context.compact(msgs, fn _ -> raise "should not summarize" end, 6_000) == msgs
  end
end

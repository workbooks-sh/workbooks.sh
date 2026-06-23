defmodule Nexus.LlmStreamTest do
  @moduledoc """
  Streaming-token support: the SSE→turn assembler must (a) deliver content deltas in order via on_token,
  (b) survive chunk boundaries that split mid-event, and (c) reassemble tool calls whose id/name/arguments
  arrive as fragments. This is the risky pure logic behind live token streaming — tested without a network.
  """
  use ExUnit.Case, async: true

  defp sse(obj), do: "data: " <> Jason.encode!(obj) <> "\n\n"

  test "content deltas stream in order and assemble into the full turn" do
    chunks = [
      sse(%{choices: [%{delta: %{content: "Hel"}}]}),
      sse(%{choices: [%{delta: %{content: "lo "}}]}),
      sse(%{choices: [%{delta: %{content: "world"}, finish_reason: "stop"}]}),
      "data: [DONE]\n\n"
    ]

    {:ok, agent} = Agent.start_link(fn -> [] end)
    on_token = fn t -> Agent.update(agent, &[t | &1]) end
    turn = Nexus.Llm.stream_assemble_for_test(chunks, on_token)

    assert turn.content == "Hello world"
    assert turn.finish == "stop"
    assert Enum.reverse(Agent.get(agent, & &1)) == ["Hel", "lo ", "world"]
  end

  test "events split across chunk boundaries are buffered and parsed" do
    full = sse(%{choices: [%{delta: %{content: "abc"}}]}) <> sse(%{choices: [%{delta: %{content: "def"}}]})
    # Split the byte stream at an arbitrary point INSIDE the first event.
    {a, b} = String.split_at(full, 12)
    turn = Nexus.Llm.stream_assemble_for_test([a, b], fn _ -> :ok end)
    assert turn.content == "abcdef"
  end

  test "tool calls reassemble from streamed fragments (id/name once, arguments concatenated)" do
    chunks = [
      sse(%{choices: [%{delta: %{tool_calls: [%{index: 0, id: "c1", function: %{name: "bash", arguments: "{\"comm"}}]}}]}),
      sse(%{choices: [%{delta: %{tool_calls: [%{index: 0, function: %{arguments: "and\":\"ls"}}]}}]}),
      sse(%{choices: [%{delta: %{tool_calls: [%{index: 0, function: %{arguments: " /work\"}"}}]}, finish_reason: "tool_calls"}]}),
      "data: [DONE]\n\n"
    ]

    turn = Nexus.Llm.stream_assemble_for_test(chunks, fn _ -> :ok end)
    assert [%{id: "c1", name: "bash", args: %{"command" => "ls /work"}}] = turn.tool_calls
    assert turn.finish == "tool_calls"
  end
end

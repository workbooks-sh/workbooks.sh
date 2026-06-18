defmodule Nexus.LlmRobustTest do
  @moduledoc "Adversarial/malformed provider payloads must degrade gracefully — never raise."
  use ExUnit.Case, async: true
  alias Nexus.Llm

  test "a response with no choices yields an empty error-turn, not a crash" do
    assert %{content: "", tool_calls: [], finish: "error"} = Llm.parse_response(%{})
    assert %{tool_calls: []} = Llm.parse_response(%{"choices" => []})
  end

  test "missing message / null content is tolerated" do
    assert %{content: "", tool_calls: []} = Llm.parse_response(%{"choices" => [%{}]})
    assert %{content: ""} = Llm.parse_response(%{"choices" => [%{"message" => %{"content" => nil}}]})
  end

  test "tool_calls with missing id/name and bad arguments degrade to safe defaults" do
    resp = %{"choices" => [%{"message" => %{"tool_calls" => [
      %{"function" => %{"name" => "bash", "arguments" => "{not json"}},   # arguments not valid JSON
      %{"function" => %{"name" => "bash", "arguments" => "[1,2]"}},        # arguments not an object
      %{"function" => %{"arguments" => "{\"command\":\"ls\"}"}},          # missing name
      %{"id" => "x"}                                                       # missing function entirely
    ]}}]}

    turn = Llm.parse_response(resp)
    args = Enum.map(turn.tool_calls, & &1.args)
    # bad JSON and non-object arguments both collapse to %{} — never a raise.
    assert Enum.at(args, 0) == %{}
    assert Enum.at(args, 1) == %{}
    assert Enum.at(args, 2) == %{"command" => "ls"}
    assert Enum.at(args, 3) == %{}
    assert Enum.at(turn.tool_calls, 2).name == nil
  end
end

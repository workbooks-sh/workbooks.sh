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

  describe "Cloudflare Workers AI routing" do
    test "workers_ai? recognizes our convention and raw @cf ids, rejects others" do
      assert Llm.workers_ai?("workers-ai/meta/llama-3.1-8b-instruct")
      assert Llm.workers_ai?("@cf/meta/llama-3.1-8b-instruct")
      refute Llm.workers_ai?("openai/gpt-4o-mini")
      refute Llm.workers_ai?(nil)
    end

    test "a CF model without a configured account id fails loud (no bad URL hit)" do
      # No CLOUDFLARE_ACCOUNT_ID in the test env → endpoint refuses rather than POSTing a broken URL.
      assert {:error, :no_cf_account} =
               Llm.complete([%{role: "user", content: "hi"}],
                 model: "workers-ai/meta/llama-3.1-8b-instruct", api_key: "cf-token")
    end

    test "a non-CF model with no key is the usual :no_api_key, unaffected by the CF path" do
      assert {:error, :no_api_key} =
               Llm.complete([%{role: "user", content: "hi"}], model: "openai/gpt-4o-mini", api_key: "")
    end

    test "model-id normalization matches the gateway vs direct endpoints" do
      # AI Gateway compat wants `workers-ai/@cf/…` (verified live: bare @cf/… → 'Invalid provider').
      assert Llm.gateway_model("@cf/meta/llama-3.1-8b-instruct-fast") == "workers-ai/@cf/meta/llama-3.1-8b-instruct-fast"
      assert Llm.gateway_model("workers-ai/@cf/meta/llama-3.1-8b-instruct-fast") == "workers-ai/@cf/meta/llama-3.1-8b-instruct-fast"
      # Direct Workers AI endpoint wants the native `@cf/…` id (no provider prefix).
      assert Llm.cf_native("workers-ai/@cf/meta/llama-3.1-8b-instruct-fast") == "@cf/meta/llama-3.1-8b-instruct-fast"
      assert Llm.cf_native("@cf/meta/llama-3.1-8b-instruct-fast") == "@cf/meta/llama-3.1-8b-instruct-fast"
    end
  end
end

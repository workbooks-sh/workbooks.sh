defmodule Workbooks.ModelResolutionTest do
  @moduledoc """
  `wb model get` must report a CONCRETE effective model id (resolving the
  built-in default), never an opaque "(default)" — an agent that can't read its
  own model can't reason about switching. (Surfaced by the multistep-model-switch
  eval: the agent reached for web_search when `wb model get` returned "(default)".)
  """
  use ExUnit.Case, async: false

  alias Workbooks.{CLI, Llm}

  setup do
    prev = System.get_env("WB_LLM_MODEL")
    System.delete_env("WB_LLM_MODEL")
    on_exit(fn -> if prev, do: System.put_env("WB_LLM_MODEL", prev), else: System.delete_env("WB_LLM_MODEL") end)
    :ok
  end

  test "Llm exposes a concrete default + effective model id" do
    assert is_binary(Llm.default_model()) and Llm.default_model() != ""
    # nothing set → effective == default
    assert Llm.effective_model() == Llm.default_model()
  end

  test "wb model get reports the concrete default (marked), not the opaque '(default)'" do
    out = CLI.call(["model", "get"], "dev")
    assert out == "#{Llm.default_model()} (default)"
    refute out == "(default)"
  end

  test "an override is reported verbatim + becomes the effective model" do
    System.put_env("WB_LLM_MODEL", "anthropic/claude-haiku-4.5")
    assert CLI.call(["model", "get"], "dev") == "anthropic/claude-haiku-4.5"
    assert Llm.effective_model() == "anthropic/claude-haiku-4.5"
  end
end

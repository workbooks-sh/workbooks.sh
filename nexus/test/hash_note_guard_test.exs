defmodule Nexus.HashNote.GuardTest do
  use ExUnit.Case, async: false

  alias Nexus.HashNote
  alias Nexus.HashNote.Guard

  setup do
    Nexus.Store.clear(HashNote.resource_mod())
    :ok
  end

  defp drawer(text) do
    HashNote.record(%{hash: "g#{System.unique_integer([:positive])}", file: "lib/x.ex", text: text, state: :collapsed, polarity: :drawer})
  end

  test "a #guard note with a /pattern/ becomes a tripwire" do
    drawer("#guard never read secrets directly — use Nexus.Secrets /System\\.get_env/")

    [v] = Guard.scan("value = System.get_env(\"OPENROUTER_API_KEY\")")
    assert v.match == "System.get_env"
    assert v.message =~ "never read secrets directly"
    assert Guard.tripped?("x = System.get_env(:foo)")
  end

  test "clean content trips nothing" do
    drawer("#guard no env reads /System\\.get_env/")
    assert Guard.scan("value = Nexus.Secrets.get(\"KEY\")") == []
    refute Guard.tripped?("all good here")
  end

  test "a plain -# note (no #guard) is never a guardrail" do
    drawer("just a normal caution, not a guard /System\\.get_env/")
    drawer("#guard but no pattern here")
    assert Guard.guards() |> Enum.count() == 0
    assert Guard.scan("System.get_env(:x)") == []
  end

  test "guards/0 lists every active guardrail" do
    drawer("#guard a /alpha/")
    drawer("#guard b /beta/")
    pats = Guard.guards() |> Enum.map(& &1.pattern) |> Enum.sort()
    assert pats == ["alpha", "beta"]
  end
end

defmodule Nexus.ChecksTest do
  @moduledoc "Self-validating workbooks. Deterministic — parse + match logic (no LLM)."
  use ExUnit.Case, async: true

  defp unit(src), do: src |> Nexus.Literate.parse() |> Enum.find(&(&1.type == :code))

  test "parse extracts agent/task/expect and seed files from a check unit" do
    n =
      unit("""
      check :unique_count do
        agent lines
        task Count the unique lines in /work/d.txt, reply UNIQUE=<n>
        seed d.txt = apple\\nbanana\\napple
        expect UNIQUE=2
      end
      """)

    c = Nexus.Checks.parse(n)
    assert c.name == "unique_count"
    assert c.agent == "lines"
    assert c.task =~ "Count the unique lines"
    assert c.expect == "UNIQUE=2"
    assert c.seed == %{"d.txt" => "apple\nbanana\napple"}
  end

  test "Compile.unit routes a check unit to the :check lane" do
    n = unit("check :x do\n  agent a\n  task t\n  expect ok\nend\n")
    assert {:check, %{name: "x", agent: "a", expect: "ok"}} = Nexus.Compile.unit(n)
  end

  test "matches? supports substring and /regex/" do
    assert Nexus.Checks.matches?("the answer is UNIQUE=2 ok", "UNIQUE=2")
    refute Nexus.Checks.matches?("UNIQUE=3", "UNIQUE=2")
    assert Nexus.Checks.matches?("count is 42", "/count is \\d+/")
    refute Nexus.Checks.matches?("count is many", "/count is \\d+/")
    assert Nexus.Checks.matches?("anything", nil)
  end

  test "run_check reports a missing-agent error instead of crashing" do
    check = %{name: "x", agent: "ghost", task: "t", expect: "ok", seed: %{}}
    r = Nexus.Checks.run_check(check, %{})
    refute r.passed
    assert r.error =~ "no agent named"
  end
end

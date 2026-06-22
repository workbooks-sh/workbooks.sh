defmodule Nexus.AgentCeilingTest do
  use ExUnit.Case, async: true
  alias Nexus.Agent

  test "declared ∩ index_ceiling ∩ parent_ceiling — capability only flows down" do
    # within both ceilings → kept
    assert Agent.effective_grant(["net", "llm"], ["net", "llm", "vfs"], nil) == ["net", "llm"]
    # index ceiling drops what it disallows
    assert Agent.effective_grant(["net", "secrets"], ["net", "llm"], nil) == ["net"]
    # parent spawn ceiling narrows further
    assert Agent.effective_grant(["net", "llm"], ["net", "llm"], ["net"]) == ["net"]
    # both compose
    assert Agent.effective_grant(["net", "llm", "secrets"], ["net", "llm"], ["net"]) == ["net"]
  end

  test "an :unbounded / nil ceiling imposes no constraint" do
    assert Agent.effective_grant(["net", "secrets"], :unbounded, nil) == ["net", "secrets"]
    assert Agent.effective_grant(["net", "secrets"], nil, nil) == ["net", "secrets"]
  end

  test "no declared grant block stays nil (all powers — back-compat)" do
    assert Agent.effective_grant(nil, ["net"], ["net"]) == nil
  end

  test "self-escalation is a no-op: declaring a cap above the ceiling cannot add it" do
    # agent rewrote its own grant to add 'secrets', but the ceiling forbids it
    assert Agent.effective_grant(["net", "secrets"], ["net"], nil) == ["net"]
  end
end

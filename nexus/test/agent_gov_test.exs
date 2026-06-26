defmodule Nexus.AgentGovTest do
  @moduledoc "Per-agent privilege budgets, over-reach clamping, and provable blast radius."
  use ExUnit.Case, async: false
  alias Nexus.AgentGov
  alias Nexus.Authz.Grants
  alias Nexus.ControlPlane, as: CP

  @org "org_ag"
  @admin %{user: "ada", role: "admin"}

  setup do
    CP.reset()
    :ok
  end

  test "budget is the agent's live grants, filtered to grantable caps" do
    Grants.grant(@org, "ws1", "agent:helper", "net", @admin)
    Grants.grant(@org, "ws1", "agent:helper", "kv", @admin)
    assert Enum.sort(AgentGov.budget(@org, "agent:helper")) == ["kv", "net"]
  end

  test "declared caps union into the budget (intended ceiling for a not-yet-granted agent)" do
    assert AgentGov.budget(@org, "agent:new", ["llm"]) == ["llm"]
  end

  test "clamp splits requested into allowed vs denied over-reach" do
    Grants.grant(@org, "ws1", "agent:helper", "net", @admin)
    budget = AgentGov.budget(@org, "agent:helper")
    assert {["net"], ["exec"]} = AgentGov.clamp(["net", "exec"], budget)
  end

  test "within_budget? is false when the agent over-reaches" do
    Grants.grant(@org, "ws1", "agent:helper", "net", @admin)
    assert AgentGov.within_budget?(@org, "agent:helper", ["net"])
    refute AgentGov.within_budget?(@org, "agent:helper", ["net", "secrets"])
  end

  describe "blast radius" do
    test "picks the most dangerous tier and flags the worst case" do
      r = AgentGov.blast_radius(["net", "exec", "kv"])
      assert r.tier == :execute
      assert r.executes? and r.destructive? and r.network?
      refute r.reads_secrets?
    end

    test "secrets is the top tier (exfil)" do
      assert AgentGov.blast_radius(["secrets", "net"]).tier == :exfil
      assert AgentGov.blast_radius(["secrets"]).reads_secrets?
    end

    test "an empty budget is tier :none — read-only" do
      r = AgentGov.blast_radius([])
      assert r.tier == :none
      refute r.destructive?
    end
  end

  describe "assurance" do
    test "summarizes an agent's maximum authority for an auditor" do
      Grants.grant(@org, "ws1", "agent:ops", "exec", @admin)
      Grants.grant(@org, "ws1", "agent:ops", "secrets", @admin)
      a = AgentGov.assurance(@org, "agent:ops")
      assert a.blast_radius.tier == :exfil
      assert a.summary =~ "read secrets"
      assert a.summary =~ "execute code"
    end

    test "a capability-less agent reports a no-authority assurance" do
      a = AgentGov.assurance(@org, "agent:reader")
      assert a.budget == []
      assert a.summary =~ "no capabilities"
    end
  end
end

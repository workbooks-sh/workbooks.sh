defmodule Nexus.AuditLogTest do
  @moduledoc "Hash-chained, tamper-evident audit log: append, chain order, verify, tamper detection."
  use ExUnit.Case, async: false
  alias Nexus.AuditLog
  alias Nexus.ControlPlane, as: CP

  @org "org_audit"

  setup do
    CP.reset()

    case AuditLog.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  test "appends form an ordered, hash-linked chain from genesis" do
    {:ok, e1} = AuditLog.append(@org, %{actor: "ada", action: "grant.issue", target: "agent:helper", details: %{cap: "net"}})
    {:ok, e2} = AuditLog.append(@org, %{actor: "ben", action: "member.offboard", target: "bob"})

    assert e1.seq == 1 and e1.prev_hash == "GENESIS"
    assert e2.seq == 2 and e2.prev_hash == e1.hash
    assert Enum.map(AuditLog.entries(@org), & &1.seq) == [1, 2]
  end

  test "verify passes on an untampered chain" do
    for i <- 1..5, do: AuditLog.append(@org, %{actor: "ada", action: "act#{i}", target: "t"})
    assert AuditLog.verify(@org) == :ok
  end

  test "verify detects a tampered entry" do
    for i <- 1..4, do: AuditLog.append(@org, %{actor: "ada", action: "act#{i}", target: "t"})
    # Forge entry 2's details directly in the store, leaving its hash stale.
    CP.update(@org, :audit, "000000000002", %{details: %{forged: true}})
    assert {:error, {:tampered_at, 2}} = AuditLog.verify(@org)
  end

  test "verify detects a deleted (broken-link) entry" do
    for i <- 1..4, do: AuditLog.append(@org, %{actor: "ada", action: "act#{i}", target: "t"})
    CP.delete(@org, :audit, "000000000002")
    # entry 3's prev_hash no longer matches entry 1's hash → break detected at seq 3
    assert {:error, {:tampered_at, 3}} = AuditLog.verify(@org)
  end

  test "logs are org-isolated" do
    AuditLog.append(@org, %{actor: "ada", action: "x", target: "t"})
    assert AuditLog.entries("org_other") == []
    assert AuditLog.verify("org_other") == :ok
  end
end

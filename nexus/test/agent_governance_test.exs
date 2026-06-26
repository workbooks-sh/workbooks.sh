defmodule Nexus.AgentGovernanceTest do
  @moduledoc "Dual-control on dangerous actions + provenance gating of high-tier capabilities."
  use ExUnit.Case, async: false
  alias Nexus.Authz.{DualControl, Provenance}
  alias Nexus.ControlPlane, as: CP

  @org "org_gov"
  @admin %{user: "ada", role: "admin"}
  @admin2 %{user: "ben", role: "admin"}
  @member %{user: "mel", role: "member"}

  setup do
    CP.reset()
    :ok
  end

  describe "dual-control" do
    test "dangerous actions are classified as requiring dual-control" do
      assert DualControl.required?("member.offboard")
      assert DualControl.required?("workspace.delete")
      assert DualControl.required?("secrets.rotate.prod")
      refute DualControl.required?("message.send")
    end

    test "request → approve by a distinct admin executes" do
      {:ok, id} = DualControl.request(@org, "member.offboard", @admin, payload: %{user: "bob"})
      refute DualControl.approved?(@org, id)
      assert {:ok, %{status: "approved", approved_by: "ben"}} = DualControl.approve(@org, id, @admin2)
      assert DualControl.approved?(@org, id)
    end

    test "the requester cannot self-approve" do
      {:ok, id} = DualControl.request(@org, "member.offboard", @admin)
      assert {:error, :self_approval} = DualControl.approve(@org, id, @admin)
      refute DualControl.approved?(@org, id)
    end

    test "a non-admin cannot approve" do
      {:ok, id} = DualControl.request(@org, "member.offboard", @admin)
      assert {:error, :approver_not_admin} = DualControl.approve(@org, id, @member)
    end

    test "pending lists open requests" do
      {:ok, _} = DualControl.request(@org, "member.offboard", @admin)
      assert length(DualControl.pending(@org)) == 1
    end
  end

  describe "provenance" do
    test "untrusted input is detected" do
      prov = Provenance.new() |> Provenance.tag(:operator, :trusted) |> Provenance.mark_untrusted(:inbound_message)
      assert Provenance.untrusted?(prov)
      assert Provenance.untrusted_sources(prov) == [:inbound_message]
    end

    test "a clean (trusted) context is not untrusted" do
      prov = Provenance.new() |> Provenance.tag(:operator, :trusted) |> Provenance.tag(:db_lookup, :tool)
      refute Provenance.untrusted?(prov)
    end

    test "high-tier capability from untrusted provenance is refused" do
      prov = Provenance.mark_untrusted(Provenance.new(), :inbound_message)
      assert {:error, {:untrusted_provenance, [:inbound_message]}} = Provenance.guard(prov, "exec")
      assert {:error, {:untrusted_provenance, _}} = Provenance.guard(prov, "secrets")
    end

    test "low-tier capability passes even from untrusted provenance" do
      prov = Provenance.mark_untrusted(Provenance.new(), :inbound_message)
      assert :ok = Provenance.guard(prov, "browse")
      assert :ok = Provenance.guard(prov, "kv")
    end

    test "high-tier capability from a trusted context passes" do
      prov = Provenance.tag(Provenance.new(), :operator, :trusted)
      assert :ok = Provenance.guard(prov, "exec")
    end
  end
end

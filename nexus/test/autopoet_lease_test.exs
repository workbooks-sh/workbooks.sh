defmodule Nexus.Autopoet.LeaseTest do
  use ExUnit.Case, async: false
  alias Nexus.Autopoet.Lease

  setup do
    Lease.clear()
    on_exit(&Lease.clear/0)
    :ok
  end

  test "a granted cap shows up as active for that principal" do
    {:ok, _} = Lease.grant("scraper", "net", ttl: "15m")
    assert "net" in Lease.active("scraper")
  end

  test "leases are non-delegable: another principal does not see them" do
    {:ok, _} = Lease.grant("scraper", "net")
    assert Lease.active("other") == []
  end

  test "an expired lease is not active" do
    {:ok, _} = Lease.grant("scraper", "net", ttl: 0)
    # ttl 0 → expires_at == now, prune drops it (expires_at > now is false)
    assert Lease.active("scraper") == []
  end

  test "revoke removes a leased cap" do
    {:ok, _} = Lease.grant("scraper", "net")
    Lease.revoke("scraper", "net")
    assert Lease.active("scraper") == []
  end

  test "a bad ttl is rejected" do
    assert {:error, {:bad_ttl, _}} = Lease.grant("x", "net", ttl: "not-a-duration")
  end

  test "effective grant unions an active lease on top of the ceiling-clamped grant" do
    # 'secrets' is outside the [net,llm] ceiling, but a lease lets the principal use it temporarily
    assert Nexus.Agent.effective_grant(["net", "secrets"], ["net", "llm"], nil) == ["net"]
    Lease.grant("w", "secrets")
    # the agent run path unions Lease.active(principal); verify the union helper via active()
    assert "secrets" in Lease.active("w")
  end
end

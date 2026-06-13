defmodule Workbooks.RevocationTest do
  use ExUnit.Case, async: false
  alias Workbooks.Revocation

  test "revoke / revoked? / unrevoke round-trip" do
    p = "rev-#{System.unique_integer([:positive])}"
    refute Revocation.revoked?(p)
    :ok = Revocation.revoke(p)
    assert Revocation.revoked?(p)
    :ok = Revocation.unrevoke(p)
    refute Revocation.revoked?(p)
  end

  test "self-audit: a revocation made by a TRANSIENT process SURVIVES that process dying (no fail-open)" do
    p = "rev-transient-#{System.unique_integer([:positive])}"

    # the revocation is made INSIDE a short-lived Task — which, under the old lazy-table pattern, would have
    # OWNED the named ETS table and taken it down (wiping ALL revocations) when it finished. A revoked
    # principal would then silently regain access. With BrokerTables owning the table, the revocation persists.
    task = Task.async(fn -> Revocation.revoke(p) end)
    :ok = Task.await(task)
    # the task has now exited; the revocation MUST still hold from this (separate, long-lived) process
    assert Revocation.revoked?(p), "revocation must survive the transient process that made it (fail-CLOSED)"

    :ok = Revocation.unrevoke(p)
  end

  test "self-audit: concurrent revokes from many transient tasks all persist (table not lost)" do
    ps = for i <- 1..200, do: "rev-conc-#{System.unique_integer([:positive])}-#{i}"

    ps
    |> Task.async_stream(fn p -> Revocation.revoke(p) end, max_concurrency: 64, ordered: false)
    |> Stream.run()

    # every concurrently-made revocation is still in effect (the table survived all the transient creators)
    assert Enum.all?(ps, &Revocation.revoked?/1)
    Enum.each(ps, &Revocation.unrevoke/1)
  end
end

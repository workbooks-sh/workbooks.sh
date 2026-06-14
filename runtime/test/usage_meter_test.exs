defmodule Workbooks.UsageMeterTest do
  use ExUnit.Case, async: false

  alias Workbooks.UsageMeter

  setup do
    prev_data = System.get_env("WB_DATA")
    prev_url = System.get_env("WB_DATABASE_URL")
    System.delete_env("WB_DATABASE_URL")
    dir = Path.join(System.tmp_dir!(), "usage-test-#{System.unique_integer([:positive])}")
    System.put_env("WB_DATA", dir)

    on_exit(fn ->
      if prev_data, do: System.put_env("WB_DATA", prev_data), else: System.delete_env("WB_DATA")
      if prev_url, do: System.put_env("WB_DATABASE_URL", prev_url)
      File.rm_rf(dir)
    end)

    {:ok, h: UsageMeter.open()}
  end

  test "record + aggregate per type", %{h: h} do
    assert {:ok, _} = UsageMeter.record("org-a", "nx-1", "compute_seconds", 10, h)
    assert {:ok, _} = UsageMeter.record("org-a", "nx-1", "compute_seconds", 5, h)
    assert {:ok, _} = UsageMeter.record("org-a", "nx-1", "storage_bytes", 1024, h)
    assert {:ok, _} = UsageMeter.record("org-a", "nx-1", "db_seconds", 3, h)

    totals = UsageMeter.usage("org-a", 0, h)
    assert totals["compute_seconds"] == 15.0
    assert totals["storage_bytes"] == 1024.0
    assert totals["db_seconds"] == 3.0
  end

  test "org A's usage excludes org B's events", %{h: h} do
    UsageMeter.record("org-a", "nx-a", "compute_seconds", 100, h)
    UsageMeter.record("org-b", "nx-b", "compute_seconds", 999, h)

    a = UsageMeter.usage("org-a", 0, h)
    b = UsageMeter.usage("org-b", 0, h)

    assert a["compute_seconds"] == 100.0
    assert b["compute_seconds"] == 999.0
    # A's totals never carry B's amount
    refute a["compute_seconds"] == 1099.0
  end

  test "nil / empty org fails closed on record and usage", %{h: h} do
    assert {:error, :no_org} = UsageMeter.record(nil, "nx", "compute_seconds", 1, h)
    assert {:error, :no_org} = UsageMeter.record("", "nx", "compute_seconds", 1, h)

    assert UsageMeter.usage(nil, 0, h) == %{}
    assert UsageMeter.usage("", 0, h) == %{}
  end

  test "rejects unknown type and non-numeric amount", %{h: h} do
    assert {:error, :invalid_type} = UsageMeter.record("org-a", "nx", "bandwidth", 1, h)
    assert {:error, :invalid_amount} = UsageMeter.record("org-a", "nx", "compute_seconds", "lots", h)
  end

  # Reproduce-then-fix (FIX #4): a negative amount must be refused — it would
  # corrupt the billing SUM. Pre-fix `not is_number(amount)` let -5 through.
  test "rejects a negative amount (billing integrity)", %{h: h} do
    assert {:error, :invalid_amount} = UsageMeter.record("org-a", "nx", "compute_seconds", -5, h)
    assert {:error, :invalid_amount} = UsageMeter.record("org-a", "nx", "storage_bytes", -1, h)
    # the negative writes never landed → no totals
    assert UsageMeter.usage("org-a", 0, h) == %{}
  end

  # FIX #5: a valid record returns {:ok, _} (the confirmed-write result), not a bare
  # :ok that ignores the DB outcome.
  test "a valid record returns {:ok, _}", %{h: h} do
    assert {:ok, amount} = UsageMeter.record("org-a", "nx", "compute_seconds", 12, h)
    assert amount == 12.0
    assert UsageMeter.usage("org-a", 0, h)["compute_seconds"] == 12.0
  end

  test "since filters out older events", %{h: h} do
    UsageMeter.record("org-a", "nx", "compute_seconds", 7, h)
    # a 'since' far in the future excludes the just-recorded event
    future = System.system_time(:second) + 10_000
    assert UsageMeter.usage("org-a", future, h) == %{}
    # all-time includes it
    assert UsageMeter.usage("org-a", 0, h)["compute_seconds"] == 7.0
  end
end

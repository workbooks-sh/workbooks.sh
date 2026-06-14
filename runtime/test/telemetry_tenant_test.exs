defmodule Workbooks.TelemetryTenantTest do
  @moduledoc """
  Tenant-scoping of workflow-run telemetry (wb-g1yo.3): /api/telemetry index +
  per-run summary must not leak another tenant's runs on a shared nexus. A run
  dir is stamped with a .tenant marker; index filters + the per-slug endpoint
  gates by run_visible?. Same grandfather rule as the session gate (nil on either
  side passes). Hermetic — uses a temp base dir.
  """
  use ExUnit.Case, async: true

  alias Workbooks.Workflow.Telemetry

  setup do
    base = Path.join(System.tmp_dir!(), "wb-tel-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  defp mkrun(base, slug, tenant) do
    wd = Path.join(base, slug)
    File.mkdir_p!(wd)
    # a minimal step log so the run isn't rejected as empty by index/2
    File.write!(Path.join(wd, "_steps.jsonl"), ~s({"tool":"shell","step":0}\n))
    File.write!(Path.join(wd, "_status.json"), ~s({"slug":"#{slug}","stage":"done"}))
    Telemetry.tag_tenant(wd, tenant)
    wd
  end

  test "run_tenant reads the marker; tag_tenant is a no-op for nil", %{base: base} do
    wd = mkrun(base, "r1", "alice")
    assert Telemetry.run_tenant(wd) == "alice"

    wd2 = mkrun(base, "r2", nil)
    assert Telemetry.run_tenant(wd2) == nil
  end

  test "run_visible? — definite mismatch denied; nil either side grandfathered", %{base: base} do
    wd = mkrun(base, "r1", "alice")
    assert Telemetry.run_visible?(wd, "alice")
    refute Telemetry.run_visible?(wd, "bob")
    assert Telemetry.run_visible?(wd, nil)

    legacy = mkrun(base, "r-legacy", nil)
    assert Telemetry.run_visible?(legacy, "bob")
  end

  test "index filters to the caller's tenant (+ legacy), hides other tenants", %{base: base} do
    mkrun(base, "alice-run", "alice")
    mkrun(base, "bob-run", "bob")
    mkrun(base, "legacy-run", nil)

    alice_slugs = Telemetry.index("alice", base) |> Enum.map(& &1.slug) |> Enum.sort()
    assert "alice-run" in alice_slugs
    assert "legacy-run" in alice_slugs
    refute "bob-run" in alice_slugs

    # nil caller = admin/internal → sees all three
    all = Telemetry.index(nil, base) |> Enum.map(& &1.slug)
    assert length(all) == 3
  end
end

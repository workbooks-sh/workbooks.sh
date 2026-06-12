defmodule Workbooks.TenantTest do
  use ExUnit.Case, async: true
  alias Workbooks.{Tenant, StorageBroker}

  test "explicit :tenant is used verbatim" do
    assert "acme" = Tenant.resolve(tenant: "acme")
  end

  test "a MISSING tenant resolves to a UNIQUE ephemeral id — never the shared 'default'" do
    a = Tenant.resolve([])
    b = Tenant.resolve([])
    refute a == "default"
    refute b == "default"
    refute a == b, "two un-tenanted resolutions must be DISJOINT (no cross-tenant collapse)"
    assert String.starts_with?(a, "eph-")
  end

  test "an empty-string tenant is treated as missing (fails to a unique ephemeral, not '')" do
    t = Tenant.resolve(tenant: "")
    refute t == ""
    assert String.starts_with?(t, "eph-")
  end

  test "wb-an2v: two un-tenanted principals CANNOT see each other's KV (the isolation property)" do
    # simulate two un-tenanted dock runs: each gets its own ephemeral principal
    {:ok, conn} = StorageBroker.open(":memory:")
    t1 = Tenant.resolve([])
    t2 = Tenant.resolve([])

    assert :ok = StorageBroker.put(conn, t1, "secret", "tenant-1-data")
    # t2 (a different un-tenanted run) must NOT read t1's key — the old shared "default" would have leaked it
    assert {:error, :not_found} = StorageBroker.get(conn, t2, "secret")
    assert {:ok, "tenant-1-data"} = StorageBroker.get(conn, t1, "secret")
  end
end

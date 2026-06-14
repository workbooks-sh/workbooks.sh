defmodule Workbooks.NexusRegistryTest do
  use ExUnit.Case, async: false
  alias Workbooks.NexusRegistry

  # Isolate the SQLite DB to a fresh temp dir per test so rows never bleed across
  # tests (and so we never touch a real data dir). WB_DATABASE_URL must be unset so
  # DB.backend() == :sqlite.
  setup do
    prev_data = System.get_env("WB_DATA")
    prev_url = System.get_env("WB_DATABASE_URL")
    System.delete_env("WB_DATABASE_URL")
    dir = Path.join(System.tmp_dir!(), "nexus-test-#{System.unique_integer([:positive])}")
    System.put_env("WB_DATA", dir)

    on_exit(fn ->
      if prev_data, do: System.put_env("WB_DATA", prev_data), else: System.delete_env("WB_DATA")
      if prev_url, do: System.put_env("WB_DATABASE_URL", prev_url)
      File.rm_rf(dir)
    end)

    {:ok, h: NexusRegistry.open()}
  end

  test "register + get round-trips, scoped to its org", %{h: h} do
    attrs = %{id: "nx-1", org_id: "org-a", fly_app: "app-a", fly_machine: "m1", region: "sjc", plan: "pro", state: "created"}
    assert {:ok, "nx-1"} = NexusRegistry.register(attrs, h)

    assert {:ok, got} = NexusRegistry.get("nx-1", "org-a", h)
    assert got.id == "nx-1"
    assert got.org_id == "org-a"
    assert got.fly_app == "app-a"
    assert got.region == "sjc"
    assert got.state == "created"
  end

  test "list is org-scoped: org A never sees org B's rows", %{h: h} do
    NexusRegistry.register(%{id: "nx-a1", org_id: "org-a"}, h)
    NexusRegistry.register(%{id: "nx-a2", org_id: "org-a"}, h)
    NexusRegistry.register(%{id: "nx-b1", org_id: "org-b"}, h)

    a_ids = NexusRegistry.list("org-a", h) |> Enum.map(& &1.id) |> Enum.sort()
    b_ids = NexusRegistry.list("org-b", h) |> Enum.map(& &1.id)

    assert a_ids == ["nx-a1", "nx-a2"]
    assert b_ids == ["nx-b1"]
    refute "nx-b1" in a_ids
  end

  test "cross-org get/set_state/update/delete are denied (never act)", %{h: h} do
    NexusRegistry.register(%{id: "nx-1", org_id: "org-a", state: "created"}, h)

    assert {:error, :not_found} = NexusRegistry.get("nx-1", "org-b", h)
    assert {:error, :not_found} = NexusRegistry.set_state("nx-1", "org-b", "running", h)
    assert {:error, :not_found} = NexusRegistry.update("nx-1", "org-b", %{region: "ord"}, h)
    assert {:error, :not_found} = NexusRegistry.delete("nx-1", "org-b", h)

    # The row is untouched by the denied ops.
    assert {:ok, got} = NexusRegistry.get("nx-1", "org-a", h)
    assert got.state == "created"
    assert got.region == nil
  end

  test "set_state + update mutate only when owned", %{h: h} do
    NexusRegistry.register(%{id: "nx-1", org_id: "org-a", state: "created"}, h)

    assert {:ok, m} = NexusRegistry.set_state("nx-1", "org-a", "running", h)
    assert m.state == "running"

    assert {:ok, m2} = NexusRegistry.update("nx-1", "org-a", %{region: "ord", fly_machine: "m9"}, h)
    assert m2.region == "ord"
    assert m2.fly_machine == "m9"
    # immutable fields stay put
    assert m2.org_id == "org-a"
  end

  test "delete removes only the owned row", %{h: h} do
    NexusRegistry.register(%{id: "nx-1", org_id: "org-a"}, h)
    assert :ok = NexusRegistry.delete("nx-1", "org-a", h)
    assert {:error, :not_found} = NexusRegistry.get("nx-1", "org-a", h)
  end

  test "owned_by? reflects the scoped ownership rule", %{h: h} do
    NexusRegistry.register(%{id: "nx-1", org_id: "org-a"}, h)
    assert NexusRegistry.owned_by?("nx-1", "org-a", h)
    refute NexusRegistry.owned_by?("nx-1", "org-b", h)
    refute NexusRegistry.owned_by?("nx-1", nil, h)
  end

  # BLOCKER-2 regression lock: org B must NOT be able to clobber org A's row by
  # colliding the id. Pre-fix `INSERT OR REPLACE` overwrote org A's row (and was
  # SQLite-only). Now a colliding id returns {:error, :exists}, row unchanged.
  test "registering an existing id under a DIFFERENT org is refused; original row untouched", %{h: h} do
    assert {:ok, "nx-1"} =
             NexusRegistry.register(
               %{id: "nx-1", org_id: "org-a", region: "sjc", state: "created", fly_app: "app-a"},
               h
             )

    # org B tries to seize the same id with different fields.
    assert {:error, :exists} =
             NexusRegistry.register(
               %{id: "nx-1", org_id: "org-b", region: "ord", state: "stolen", fly_app: "app-b"},
               h
             )

    # org B still cannot see it (ownership unchanged)…
    assert {:error, :not_found} = NexusRegistry.get("nx-1", "org-b", h)

    # …and org A's original row is byte-for-byte intact.
    assert {:ok, got} = NexusRegistry.get("nx-1", "org-a", h)
    assert got.org_id == "org-a"
    assert got.region == "sjc"
    assert got.state == "created"
    assert got.fly_app == "app-a"

    # same-org re-register is also refused (no clobber, ever).
    assert {:error, :exists} = NexusRegistry.register(%{id: "nx-1", org_id: "org-a", region: "lax"}, h)
    assert {:ok, %{region: "sjc"}} = NexusRegistry.get("nx-1", "org-a", h)
  end

  test "update ignores non-whitelisted columns (no SQL interpolation of unknown keys)", %{h: h} do
    NexusRegistry.register(%{id: "nx-1", org_id: "org-a", region: "sjc"}, h)

    # org_id/id/created are immutable, and a bogus column is dropped entirely.
    assert {:ok, m} =
             NexusRegistry.update(
               "nx-1",
               "org-a",
               %{"id" => "nx-evil", "DROP" => "x", region: "ord", org_id: "org-evil", created: 0},
               h
             )

    assert m.region == "ord"
    assert m.org_id == "org-a"
    assert m.id == "nx-1"
    # The row is still fetchable under its real org/id (nothing was renamed/moved).
    assert {:ok, _} = NexusRegistry.get("nx-1", "org-a", h)
  end

  test "nil / empty org_id fails closed on every path", %{h: h} do
    NexusRegistry.register(%{id: "nx-1", org_id: "org-a"}, h)

    # reads see nothing
    assert NexusRegistry.list(nil, h) == []
    assert NexusRegistry.list("", h) == []
    assert {:error, :not_found} = NexusRegistry.get("nx-1", nil, h)
    assert {:error, :not_found} = NexusRegistry.get("nx-1", "", h)

    # mutations refuse
    assert {:error, :not_found} = NexusRegistry.set_state("nx-1", nil, "running", h)
    assert {:error, :not_found} = NexusRegistry.delete("nx-1", "", h)

    # registering an unowned nexus is refused
    assert {:error, :no_org} = NexusRegistry.register(%{id: "nx-x", org_id: nil}, h)
    assert {:error, :no_org} = NexusRegistry.register(%{id: "nx-x", org_id: ""}, h)
    assert {:error, :invalid_id} = NexusRegistry.register(%{id: "", org_id: "org-a"}, h)
  end
end

defmodule Nexus.ShapesTest do
  @moduledoc "Live-shapes: store writes push access-checked deltas to matching subscribers only."
  use ExUnit.Case, async: false

  setup_all do
    # A duplicate-key Registry — same spec the app supervises; start it for the test run if absent.
    case Registry.start_link(keys: :duplicate, name: Nexus.Shapes.Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    mod =
      "resource Msg do\n  channel :text\n  body :text\n  parent :text\nend\n"
      |> Nexus.Literate.parse()
      |> Enum.find(&(&1.type == :code))
      |> Nexus.Resource.compile()

    {:ok, mod: mod}
  end

  setup %{mod: mod} do
    Nexus.Store.clear(mod, "t1")
    Nexus.Store.clear(mod, "t2")
    :ok
  end

  test "a store insert pushes an :insert delta carrying the row", %{mod: mod} do
    :ok = Nexus.Shapes.subscribe(mod, "t1")
    {:ok, _} = Nexus.Store.create(mod, %{channel: "general", body: "hi"}, "t1")

    assert_receive {:shape_delta, %{resource: ^mod, tenant: "t1", op: :insert, row: row}}, 500
    assert row.body == "hi"
  end

  test "the filter gates fan-out — a delta the subscriber can't see never arrives", %{mod: mod} do
    # Only watch channel "general".
    :ok = Nexus.Shapes.subscribe(mod, "t1", &(&1.channel == "general"))

    {:ok, _} = Nexus.Store.create(mod, %{channel: "random", body: "nope"}, "t1")
    refute_receive {:shape_delta, _}, 200

    {:ok, _} = Nexus.Store.create(mod, %{channel: "general", body: "yes"}, "t1")
    assert_receive {:shape_delta, %{op: :insert, row: %{body: "yes"}}}, 500
  end

  test "tenant partition: a t2 write never reaches a t1 subscriber", %{mod: mod} do
    :ok = Nexus.Shapes.subscribe(mod, "t1")
    {:ok, _} = Nexus.Store.create(mod, %{channel: "general", body: "other-tenant"}, "t2")
    refute_receive {:shape_delta, _}, 200
  end

  test "snapshot returns current filtered rows for a freshly-opened shape", %{mod: mod} do
    {:ok, _} = Nexus.Store.create(mod, %{channel: "general", body: "a"}, "t1")
    {:ok, _} = Nexus.Store.create(mod, %{channel: "random", body: "b"}, "t1")

    snap = Nexus.Shapes.snapshot(mod, "t1", &(&1.channel == "general"))
    assert Enum.map(snap, & &1.body) == ["a"]
  end

  test "the subscribable-shape allowlist resolves names safely; unknown → :error", %{mod: mod} do
    Nexus.Shapes.register("msgs", mod, :channel)
    assert {^mod, :channel} = Nexus.Shapes.resolve("msgs")
    assert :error = Nexus.Shapes.resolve("definitely-not-registered")
  end

  test "a filter that raises is fail-closed (no delivery, no crash)", %{mod: mod} do
    :ok = Nexus.Shapes.subscribe(mod, "t1", fn _ -> raise "boom" end)
    {:ok, _} = Nexus.Store.create(mod, %{channel: "general", body: "x"}, "t1")
    refute_receive {:shape_delta, _}, 200
  end
end

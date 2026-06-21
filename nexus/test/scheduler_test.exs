defmodule Nexus.SchedulerTest do
  use ExUnit.Case, async: false
  alias Nexus.Scheduler

  setup do
    # A test sink effect that forwards each fire to the test process.
    parent = self()
    Nexus.Effects.register("test_sink", fn args, _event, _ctx -> send(parent, {:fired, args[:value]}); :ok end)
    Scheduler.clear()
    on_exit(fn -> Scheduler.clear() end)
    :ok
  end

  defp sink(value), do: %{name: "test_sink", args: %{value: value}}

  test "arm + list + disarm" do
    assert :ok = Scheduler.arm("nightly", [cron: "0 2 * * *"], [sink(:n)])
    assert [%{name: "nightly", tenant: "default"}] = Scheduler.list()
    assert :ok = Scheduler.disarm("nightly")
    assert [] = Scheduler.list()
  end

  test "a one-shot fires once then drops" do
    assert :ok = Scheduler.arm("soon", %{kind: :after, ms: 30}, [sink(:once)])
    assert_receive {:fired, :once}, 500
    # one-shot self-removes after firing
    Process.sleep(20)
    assert [] = Scheduler.list()
  end

  test "a repeating schedule re-arms and fires again" do
    assert :ok = Scheduler.arm("tick", %{kind: :every, ms: 40}, [sink(:tick)])
    assert_receive {:fired, :tick}, 500
    assert_receive {:fired, :tick}, 500
    # still armed (repeating)
    assert [%{name: "tick"}] = Scheduler.list()
  end

  test "fire_now runs effects without consuming the timer" do
    assert :ok = Scheduler.arm("manual", [cron: "0 2 * * *"], [sink(:manual)])
    assert :ok = Scheduler.fire_now("manual")
    assert_receive {:fired, :manual}, 500
    assert [%{name: "manual"}] = Scheduler.list()
  end

  test "re-arming the same name replaces, not duplicates" do
    assert :ok = Scheduler.arm("dup", [cron: "0 2 * * *"], [sink(:a)])
    assert :ok = Scheduler.arm("dup", [cron: "0 3 * * *"], [sink(:b)])
    assert [%{name: "dup"}] = Scheduler.list()
  end

  test "tenant isolation in listing" do
    assert :ok = Scheduler.arm("t1", [cron: "0 2 * * *"], [sink(:x)], tenant: "org-a")
    assert :ok = Scheduler.arm("t2", [cron: "0 2 * * *"], [sink(:y)], tenant: "org-b")
    assert [%{tenant: "org-a"}] = Scheduler.list(tenant: "org-a")
    assert [%{tenant: "org-b"}] = Scheduler.list(tenant: "org-b")
  end

  test "bad time spec is rejected at arm" do
    assert {:error, _} = Scheduler.arm("bad", [every: "banana"], [sink(:z)])
  end

  test "fires the real `run flow` / `emit` effects through the open registry" do
    # prove the scheduler reuses Nexus.Effects: emit lands on the bus.
    parent = self()
    Nexus.Events.subscribe(fn ev -> ev[:kind] == "scheduled.ping" end)
    Nexus.Effects.register("emit", fn args, _e, ctx ->
      Nexus.Events.emit(args, depth: Map.get(ctx, :depth, 0) + 1)
      send(parent, :emitted)
      :ok
    end)

    assert :ok = Scheduler.arm("ping", %{kind: :after, ms: 30}, [%{name: "emit", args: %{kind: "scheduled.ping"}}])
    assert_receive :emitted, 500
  end
end

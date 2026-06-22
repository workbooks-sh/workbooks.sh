defmodule Nexus.Autopoet.ControlTest do
  use ExUnit.Case, async: false
  alias Nexus.Autopoet.{Worker, Lease}
  alias Nexus.Scheduler

  setup do
    Worker.disarm()
    Lease.clear()
    try do :persistent_term.erase({Nexus.Autopoet.Worker, :last_cycle}) rescue _ -> :ok end
    on_exit(fn -> Worker.disarm(); Lease.clear() end)
    :ok
  end

  test "arm/disarm toggles the heartbeat; status reflects it" do
    assert Worker.status().armed == false
    Worker.arm("15m")
    s = Worker.status()
    assert s.armed == true
    assert is_integer(s.next_ms) and s.next_ms > 0
    Worker.disarm()
    assert Worker.status().armed == false
  end

  test "run_once records the last cycle report" do
    Worker.run_once(root: System.tmp_dir!(), requests: [], learn?: false)
    last = Worker.status().last
    assert is_map(last) and Map.has_key?(last, :sensed) and Map.has_key?(last, :at)
  end

  test "firing the heartbeat schedule runs a cycle (effect wired)" do
    Worker.arm("15m")
    :ok = Scheduler.fire_now("autopoet.heartbeat")
    # the effect runs in a supervised Task (async) — poll briefly for it to stamp a last report
    assert Enum.any?(1..50, fn _ -> is_map(Worker.status().last) || (Process.sleep(20) && false) end)
  end

  test "access reports management postures, leases, and impurity" do
    Lease.grant("scraper", "net", ttl: "10m")
    a = Worker.access(root: System.tmp_dir!())
    assert is_list(a.agents)
    assert is_integer(a.managed) and is_integer(a.frozen)
    assert Enum.any?(a.leases, &(&1.principal == "scraper" and &1.cap == "net"))
    assert is_list(a.impure_indexes)
  end
end

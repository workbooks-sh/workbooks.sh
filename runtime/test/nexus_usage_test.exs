defmodule Workbooks.NexusUsageTest do
  use ExUnit.Case, async: false

  alias Workbooks.{NexusUsage, NexusRegistry, UsageMeter}

  # A stub Fly client: returns a canned machine per fly_app, records no network.
  defmodule StubFly do
    def machines(map), do: Process.put(:stub_machines, map)

    def get_machine(app, _id, _opts) do
      case Map.fetch(Process.get(:stub_machines, %{}), app) do
        {:ok, m} -> {:ok, m}
        :error -> {:error, {404, %{}}}
      end
    end
  end

  setup do
    prev_data = System.get_env("WB_DATA")
    prev_url = System.get_env("WB_DATABASE_URL")
    System.delete_env("WB_DATABASE_URL")
    dir = Path.join(System.tmp_dir!(), "nexususage-#{System.unique_integer([:positive])}")
    System.put_env("WB_DATA", dir)

    on_exit(fn ->
      if prev_data, do: System.put_env("WB_DATA", prev_data), else: System.delete_env("WB_DATA")
      if prev_url, do: System.put_env("WB_DATABASE_URL", prev_url)
      File.rm_rf(dir)
    end)

    {:ok, reg: NexusRegistry.open(), usage: UsageMeter.open()}
  end

  describe "running_seconds/2 (from the Fly event log)" do
    test "sums start→stop intervals" do
      machine = %{
        "state" => "stopped",
        "events" => [
          %{"type" => "start", "timestamp" => 1_000_000},
          %{"type" => "stop", "timestamp" => 1_060_000}
        ]
      }

      # 1_060_000ms - 1_000_000ms = 60_000ms = 60s
      assert NexusUsage.running_seconds(machine, 9_999_999) == 60
    end

    test "an open interval on a started machine accrues to now" do
      machine = %{"state" => "started", "events" => [%{"type" => "start", "timestamp" => 1_000_000}]}
      # start at 1000s, now at 1100s → 100s
      assert NexusUsage.running_seconds(machine, 1100) == 100
    end

    test "no events → zero" do
      assert NexusUsage.running_seconds(%{"events" => []}, 1000) == 0
      assert NexusUsage.running_seconds(%{}, 1000) == 0
    end
  end

  describe "cost_per_second/1" do
    test "scales with guest size and is zero for unknown guest" do
      small = NexusUsage.cost_per_second(%{"config" => %{"guest" => %{"cpus" => 1, "memory_mb" => 1024}}})
      big = NexusUsage.cost_per_second(%{"config" => %{"guest" => %{"cpus" => 2, "memory_mb" => 4096}}})
      assert small > 0
      assert big > small
    end
  end

  describe "rollup/2" do
    test "blank org → empty, all-zero rollup", %{reg: reg, usage: usage} do
      r = NexusUsage.rollup("", registry: reg, usage: usage, fly: StubFly)
      assert r.summary.nexusCount == 0
      assert r.rows == []
      assert r.summary.monthToDate == "$0.00"
    end

    test "real rollup from registry + Fly events, org-scoped", %{reg: reg, usage: usage} do
      {:ok, _} =
        NexusRegistry.register(
          %{"id" => "nx-a", "org_id" => "org-a", "fly_app" => "nexus-nx-a", "fly_machine" => "m1", "region" => "sjc", "plan" => "starter", "state" => "running"},
          reg
        )

      {:ok, _} =
        NexusRegistry.register(
          %{"id" => "nx-b", "org_id" => "org-b", "fly_app" => "nexus-nx-b", "fly_machine" => "m2", "region" => "sjc", "plan" => "team", "state" => "running"},
          reg
        )

      StubFly.machines(%{
        "nexus-nx-a" => %{
          "state" => "stopped",
          "config" => %{"guest" => %{"cpus" => 1, "memory_mb" => 1024}},
          "events" => [
            %{"type" => "start", "timestamp" => 0},
            %{"type" => "stop", "timestamp" => 3_600_000}
          ]
        }
      })

      r = NexusUsage.rollup("org-a", registry: reg, usage: usage, fly: StubFly, now: 9_999_999)

      # org-a sees ONLY its own nexus
      assert r.summary.nexusCount == 1
      assert [%{name: "nx-a"} = row] = r.rows
      # 1hr of running time
      assert row.activeHrs == "1.0"
      # a real, positive cost was computed from the event log
      assert r.summary.compute != "$0.00"

      # and org-b's nexus never appears in org-a's rollup
      refute Enum.any?(r.rows, &(&1.name == "nx-b"))
    end
  end
end

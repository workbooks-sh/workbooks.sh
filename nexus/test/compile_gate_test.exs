defmodule Nexus.Compile.GateTest do
  use ExUnit.Case, async: false
  alias Nexus.Compile.Gate

  # The Gate is a singleton started by the app; its limit = WB_COMPILE_CONCURRENCY or schedulers.
  test "with_slot caps live concurrency to the limit and queues the rest" do
    limit = Gate.stats().limit
    {:ok, peak} = Agent.start_link(fn -> {0, 0} end) # {current, max}

    tasks =
      for _ <- 1..(limit * 3) do
        Task.async(fn ->
          Gate.with_slot(fn ->
            Agent.update(peak, fn {c, m} -> {c + 1, max(m, c + 1)} end)
            Process.sleep(30)
            Agent.update(peak, fn {c, m} -> {c - 1, m} end)
          end)
        end)
      end

    Task.await_many(tasks, 30_000)
    {_, max_seen} = Agent.get(peak, & &1)
    assert max_seen <= limit, "peak concurrency #{max_seen} exceeded the cap #{limit}"
    assert Gate.stats().in_use == 0 and Gate.stats().queued == 0
  end

  test "a killed slot-holder doesn't leak its slot (monitor recovery)" do
    before = Gate.stats().in_use
    pid = spawn(fn -> Gate.with_slot(fn -> Process.sleep(:infinity) end) end)
    Process.sleep(50)
    assert Gate.stats().in_use == before + 1
    Process.exit(pid, :kill)
    Process.sleep(50)
    assert Gate.stats().in_use == before, "slot leaked after the holder was killed"
  end
end

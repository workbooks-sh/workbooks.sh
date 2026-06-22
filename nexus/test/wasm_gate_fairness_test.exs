defmodule Nexus.Wasm.GateFairnessTest do
  use ExUnit.Case, async: false

  alias Nexus.Wasm.Gate

  # wb-whvy — the gate must (1) be work-conserving (one tenant can use the whole lane), and (2) under
  # contention hand a freed slot to the waiting tenant holding the FEWEST slots, so one tenant cannot
  # starve others by bursting requests.

  # A holder: acquires a slot, announces it, then parks until told to release.
  defp hold(lane, tenant, test_pid) do
    spawn(fn ->
      Gate.with_slot(lane, tenant, fn ->
        send(test_pid, {:acquired, self()})
        receive do: (:release -> :ok)
      end)
    end)
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries <= 0 -> flunk("condition not met")
      true -> Process.sleep(5); wait_until(fun, tries - 1)
    end
  end

  test "work-conserving: a single tenant can fill the whole lane" do
    {:ok, _} = Gate.start_link(lane: :wc, limit: 3)
    for _ <- 1..3, do: hold(:wc, "solo", self())
    for _ <- 1..3, do: assert_receive({:acquired, _}, 500)
    assert Gate.stats(:wc).in_use == 3
  end

  test "under contention a freed slot goes to the starved tenant, not FIFO" do
    {:ok, _} = Gate.start_link(lane: :fair, limit: 2)

    # Tenant A grabs both slots.
    a1 = hold(:fair, "A", self())
    assert_receive {:acquired, ^a1}, 500
    a2 = hold(:fair, "A", self())
    assert_receive {:acquired, ^a2}, 500

    # Queue another A waiter FIRST, then a B waiter — deterministically (poll the queue depth).
    a3 = hold(:fair, "A", self())
    wait_until(fn -> Gate.stats(:fair).queued == 1 end)
    b = hold(:fair, "B", self())
    wait_until(fn -> Gate.stats(:fair).queued == 2 end)

    # Free one A slot. Max-min fairness must hand it to B (0 holders) over A3 (A still holds 1),
    # even though A3 queued first.
    send(a1, :release)
    assert_receive {:acquired, ^b}, 500
    refute_receive {:acquired, ^a3}, 100

    # Drain: release the rest; A3 eventually gets a slot.
    send(a2, :release)
    assert_receive {:acquired, ^a3}, 500
  end

  test "back-compat: with_slot/2 (no tenant) still runs under :shared" do
    {:ok, _} = Gate.start_link(lane: :compat, limit: 1)
    assert Gate.with_slot(:compat, fn -> :ran end) == :ran
  end
end

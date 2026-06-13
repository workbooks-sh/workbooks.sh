defmodule Workbooks.ProcessBrokerTest do
  use ExUnit.Case, async: false
  alias Workbooks.ProcessBroker

  test "FORK-BOMB DEFENSE — a principal cannot exceed its concurrent-process cap" do
    p = "proc-bomb-#{System.unique_integer([:positive])}"
    # a never-finishing command would hold slots; use a blocking handler-free path by spawning real commands
    # with a tiny cap and NOT awaiting, so the slots stay reserved. cap = 3.
    handles =
      for _ <- 1..3 do
        {:ok, h} = ProcessBroker.spawn("sleepy", [], "", allow: true, principal: p, max_processes: 3)
        h
      end

    # the 4th spawn while 3 are live must be refused — the fork-bomb gate
    assert {:error, :max_processes} =
             ProcessBroker.spawn("sleepy", [], "", allow: true, principal: p, max_processes: 3)

    # awaiting one frees a slot -> a new spawn fits again
    _ = ProcessBroker.await(hd(handles), 5_000)
    assert {:ok, _} = ProcessBroker.spawn("sleepy", [], "", allow: true, principal: p, max_processes: 3)
  end

  test "DEFAULT-DENY — a spawn without the exec grant fails at await (ExecBroker cadence applies per process)" do
    p = "proc-deny-#{System.unique_integer([:positive])}"
    {:ok, h} = ProcessBroker.spawn("coreutils", ["cat"], "x", allow: false, principal: p)
    assert {:error, :denied} = ProcessBroker.await(h, 5_000)
  end

  @tag :build
  @tag timeout: 300_000
  test "ASYNC LIFECYCLE — spawn N sandboxed subprocesses, await each (the fork-exec primitive, real wasm)" do
    assert :ok = Workbooks.Pallet.seed_one("coreutils")
    p = "proc-async-#{System.unique_integer([:positive])}"

    # spawn 3 sandboxed `coreutils cat` subprocesses concurrently (non-blocking), each with its own stdin
    handles =
      for input <- ["alpha", "beta", "gamma"] do
        {:ok, h} = ProcessBroker.spawn("coreutils", ["cat"], input, allow: true, principal: p)
        {input, h}
      end

    # await each -> the subprocess echoed its stdin (ran in a fresh isolated wasm instance)
    for {input, h} <- handles do
      assert {:ok, ^input} = ProcessBroker.await(h, 30_000)
    end

    # all slots released after await -> live count back to 0
    assert ProcessBroker.live_count(p) == 0
  end
end

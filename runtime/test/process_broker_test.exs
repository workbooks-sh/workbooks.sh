defmodule Workbooks.ProcessBrokerTest do
  use ExUnit.Case, async: false
  alias Workbooks.ProcessBroker

  # slot release (reap/parent-death) happens in the worker process, asynchronously relative to await's return,
  # so the per-principal count is eventually-consistent — poll for it.
  defp assert_live_count(principal, expected, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    poll = fn poll ->
      if ProcessBroker.live_count(principal) == expected do
        :ok
      else
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(25)
          poll.(poll)
        else
          flunk("live_count(#{principal}) = #{ProcessBroker.live_count(principal)}, expected #{expected}")
        end
      end
    end

    poll.(poll)
  end

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

  test "NO SLOT LEAK — an ABANDONED (never-awaited) process auto-releases its slot at max_lifetime" do
    p = "proc-abandon-#{System.unique_integer([:positive])}"
    # spawn-and-abandon (never await) with a short lifetime; the slot must free itself so the cap isn't
    # permanently exhausted by a guest that just drops handles (self-DoS resistance).
    {:ok, _h} = ProcessBroker.spawn("nope", [], "", allow: true, principal: p, max_lifetime: 300)
    assert ProcessBroker.live_count(p) == 1
    assert_live_count(p, 0, 2_000)
  end

  test "NO SLOT LEAK — a process whose PARENT dies releases its slot" do
    p = "proc-orphan-#{System.unique_integer([:positive])}"
    test_pid = self()

    # a short-lived parent process spawns one then exits WITHOUT reaping -> the orphan must release.
    parent =
      spawn(fn ->
        {:ok, _h} = ProcessBroker.spawn("nope", [], "", allow: true, principal: p, max_lifetime: 30_000)
        send(test_pid, :spawned)
        # exit immediately, orphaning the process
      end)

    assert_receive :spawned, 2_000
    ref = Process.monitor(parent)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    # the worker monitors the parent; its death frees the slot promptly (well before max_lifetime)
    assert_live_count(p, 0, 2_000)
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
    assert_live_count(p, 0)
  end
end

defmodule Nexus.WashyThreadsTest do
  @moduledoc """
  WASIX §2 THREADS — real futex (atomic.wait/notify across BEAM processes on shared `:atomics` memory)
  + thread_spawn over BEAM processes sharing linear memory. The enabler: `:washy_mem` is an `:atomics`
  ref, shareable across processes, so a spawned thread reads/writes the SAME memory as its parent. Each
  thread gets its OWN globals copy (independent stack pointer) but SHARES memory + table.

  These tests drive `Nexus.Washy.guest_atomic_wait/notify` directly with a hand-installed shared memory
  (the ONE impl the interpreter step and the asm lane both call), and exercise thread_spawn end-to-end.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy
  alias Nexus.Washy.TranspileAsm

  # Install a shared `:atomics`-backed memory of `pages` 64KB pages into THIS process's dict, so the
  # guest_atomic_* helpers (which read :washy_mem / :washy_mem_pages) operate on it. Returns the refs so
  # a spawned process can adopt the SAME ones (true sharing).
  defp install_mem(pages \\ 1) do
    mem = :atomics.new(pages * 8192, signed: false)
    mem_pages = :atomics.new(1, signed: false)
    :atomics.put(mem_pages, 1, pages)
    Process.put(:washy_mem, mem)
    Process.put(:washy_mem_pages, mem_pages)
    Process.put(:washy_max_pages, pages)
    {mem, mem_pages}
  end

  defp adopt_mem(mem, mem_pages) do
    Process.put(:washy_mem, mem)
    Process.put(:washy_mem_pages, mem_pages)
    Process.put(:washy_max_pages, 64)
  end

  setup do
    # a fresh futex bag per test run isn't possible (named/public), but keys are mem-ref scoped so
    # different tests' memories never collide. Just ensure it exists.
    if :ets.whereis(:washy_futex) == :undefined do
      :ets.new(:washy_futex, [:named_table, :public, :bag])
    end

    :ok
  end

  test "futex wait BLOCKS then is WOKEN across processes (return 0)" do
    {mem, mem_pages} = install_mem()
    # write expected value 7 @ addr 0
    :atomics.put(mem, 1, 7)

    test_pid = self()

    waiter =
      Task.async(fn ->
        adopt_mem(mem, mem_pages)
        send(test_pid, :ready)
        t0 = System.monotonic_time(:millisecond)
        rc = Washy.guest_atomic_wait(0, 7, 4, 1_000_000_000)
        {rc, System.monotonic_time(:millisecond) - t0}
      end)

    assert_receive :ready, 1_000
    # let the waiter actually park before notifying
    Process.sleep(30)
    assert Washy.guest_atomic_notify(0, 1) == 1

    {rc, elapsed} = Task.await(waiter, 2_000)
    assert rc == 0, "expected woken (0), got #{rc}"
    assert elapsed >= 15, "expected to have BLOCKED (>=15ms), waited #{elapsed}ms"
  end

  test "futex wait returns 1 immediately when mem != expected" do
    {mem, _} = install_mem()
    :atomics.put(mem, 1, 42)
    t0 = System.monotonic_time(:millisecond)
    assert Washy.guest_atomic_wait(0, 7, 4, 1_000_000_000) == 1
    assert System.monotonic_time(:millisecond) - t0 < 50, "should not block on not-equal"
  end

  test "futex wait times out (return 2) after the bounded wait when never notified" do
    {mem, _} = install_mem()
    :atomics.put(mem, 1, 99)
    t0 = System.monotonic_time(:millisecond)
    # expecting 99 (== mem) so it parks; small timeout → returns 2
    assert Washy.guest_atomic_wait(0, 99, 4, 40_000_000) == 2
    assert System.monotonic_time(:millisecond) - t0 >= 30, "should have waited ~the timeout"
  end

  test "notify wakes exactly N of M waiters; the rest time out" do
    {mem, mem_pages} = install_mem()
    :atomics.put(mem, 1, 5)
    test_pid = self()

    waiters =
      for _ <- 1..3 do
        Task.async(fn ->
          adopt_mem(mem, mem_pages)
          send(test_pid, :ready)
          # generous park timeout so only an explicit notify returns 0; un-notified → 2
          Washy.guest_atomic_wait(0, 5, 4, 300_000_000)
        end)
      end

    for _ <- 1..3, do: assert_receive(:ready, 1_000)
    Process.sleep(40)

    assert Washy.guest_atomic_notify(0, 2) == 2

    results = Enum.map(waiters, &Task.await(&1, 2_000))
    assert Enum.count(results, &(&1 == 0)) == 2, "exactly 2 woken: #{inspect(results)}"
    assert Enum.count(results, &(&1 == 2)) == 1, "the third times out: #{inspect(results)}"
  end

  test "notify(-1) wakes ALL waiters" do
    {mem, mem_pages} = install_mem()
    :atomics.put(mem, 1, 3)
    test_pid = self()

    waiters =
      for _ <- 1..3 do
        Task.async(fn ->
          adopt_mem(mem, mem_pages)
          send(test_pid, :ready)
          Washy.guest_atomic_wait(0, 3, 4, 300_000_000)
        end)
      end

    for _ <- 1..3, do: assert_receive(:ready, 1_000)
    Process.sleep(40)

    assert Washy.guest_atomic_notify(0, 0xFFFFFFFF) == 3
    assert Enum.all?(Enum.map(waiters, &Task.await(&1, 2_000)), &(&1 == 0))
  end

  test "spawned BEAM thread shares the parent's :atomics memory (writes are visible)" do
    # Prove the shared-memory primitive: a spawned process adopts the SAME :washy_mem ref and its
    # writes are seen by the parent — exactly what thread_spawn relies on (no copy).
    {mem, mem_pages} = install_mem()
    :atomics.put(mem, 1, 0)
    test_pid = self()

    spawn(fn ->
      adopt_mem(mem, mem_pages)
      # write sentinel 0xCAFE @ word 1 (addr 0) via the guest store path
      Washy.guest_store(0, 0xCAFE, 4)
      send(test_pid, :wrote)
    end)

    assert_receive :wrote, 1_000
    # parent reads the SAME memory and sees the sentinel
    assert Washy.guest_load(0, 4) == 0xCAFE
  end

  test "thread_spawn runs the module's wasi_thread_start in a process sharing memory" do
    # A module whose wasi_thread_start(tid, start_arg) writes start_arg @ addr 16 in SHARED memory.
    # body: (i32.store (i32.const 16) (local.get 1))  ; local 1 = start_arg (2nd param)
    instrs = [
      {:i32_const, 16},
      {:local_get, 1},
      {:i32_store, 0},
      {:return}
    ]

    mod = %Washy{
      types: [{[127, 127], []}],
      funcs: [0],
      code: [{0, instrs}],
      exports: %{"wasi_thread_start" => 0, "_start" => 0},
      # SHARED memory (flag 3): pre-allocated at max so grow never reallocates under threads.
      mem: {1, 64, :shared},
      globals: [],
      data: [],
      imports: [],
      elements: [],
      id: :crypto.hash(:sha256, :erlang.term_to_binary(instrs))
    }

    # Drive _start which spawns a thread that writes 0xBEEF @16, then read it back from shared memory.
    # We use call_io to set up the run context, but _start itself is a no-op here; instead we directly
    # exercise guest_thread_spawn within a live run context via instance_start.
    {:ok, inst, _out} = Washy.instance_start(mod, "_start", [0, 0])

    # re-enter the run context the instance holds, then spawn a thread with start_arg=0xBEEF.
    Process.put(:washy_mem, inst.mem)
    Process.put(:washy_mem_pages, inst.mem_pages)
    Process.put(:washy_max_pages, inst.max_pages)
    Process.put(:washy_mem_shared, true)
    Process.put(:washy_globals, inst.globals)
    Process.put(:washy_table, inst.table)
    Process.put(:washy_rt, inst.rt)

    tid = Washy.guest_thread_spawn(0xBEEF)
    assert tid >= 1

    # wait for the thread to write the sentinel into shared memory @16
    assert eventually(fn -> Washy.guest_load(16, 4) == 0xBEEF end)
  end

  test "interp == asm for atomic.wait (not-equal + timeout) and notify lowers" do
    # A function: local0=addr, local1=expected, local2=timeout → i32 wait result.
    # (memory.atomic.wait32 (local.get 0) (local.get 1) (local.get 2))
    wait_instrs = [
      {:local_get, 0},
      {:local_get, 1},
      {:local_get, 2},
      {:atomic_wait, 4, 0}
    ]

    m = %Washy{
      types: [{[127, 127, 127], [127]}],
      funcs: [0],
      code: [{0, wait_instrs}],
      exports: %{"f" => 0},
      mem: {1, nil},
      globals: [],
      data: [],
      imports: [],
      elements: [],
      id: :crypto.hash(:sha256, :erlang.term_to_binary(wait_instrs))
    }

    assert {:ok, {_am, _af, _}} = TranspileAsm.try_emit(m, 0), "atomic.wait should lower to asm"

    # not-equal: mem@0 = 0 (fresh), expected 7, timeout 0 → 1, immediately (deterministic)
    {interp_ne, _} = Washy.call_io(m, "f", [0, 7, 0], transpile: false)
    {asm_ne, _} = Washy.call_io(m, "f", [0, 7, 0], transpile: true, tier_threshold: 1, tier_async: false)
    assert interp_ne == 1 and asm_ne == 1, "ne: interp=#{interp_ne} asm=#{asm_ne}"

    # timeout: mem@0 = 0, expected 0 (matches), timeout 0 → parks then immediately returns 2
    {interp_to, _} = Washy.call_io(m, "f", [0, 0, 0], transpile: false)
    {asm_to, _} = Washy.call_io(m, "f", [0, 0, 0], transpile: true, tier_threshold: 1, tier_async: false)
    assert interp_to == 2 and asm_to == 2, "timeout: interp=#{interp_to} asm=#{asm_to}"

    # notify lowers too: (memory.atomic.notify (local.get 0) (local.get 1)) → woken (0 here)
    notify_instrs = [{:local_get, 0}, {:local_get, 1}, {:atomic_notify, 0}]

    mn = %Washy{
      types: [{[127, 127], [127]}],
      funcs: [0],
      code: [{0, notify_instrs}],
      exports: %{"f" => 0},
      mem: {1, nil},
      globals: [],
      data: [],
      imports: [],
      elements: [],
      id: :crypto.hash(:sha256, :erlang.term_to_binary(notify_instrs))
    }

    assert {:ok, {_am, _af, _}} = TranspileAsm.try_emit(mn, 0), "atomic.notify should lower to asm"
    {interp_n, _} = Washy.call_io(mn, "f", [0, 1], transpile: false)
    {asm_n, _} = Washy.call_io(mn, "f", [0, 1], transpile: true, tier_threshold: 1, tier_async: false)
    assert interp_n == 0 and asm_n == 0, "notify: interp=#{interp_n} asm=#{asm_n}"
  end

  # bounded poll: true within ~1s or false.
  defp eventually(fun, tries \\ 100) do
    Enum.reduce_while(1..tries, false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: (Process.sleep(10); {:cont, false})
    end)
  end
end

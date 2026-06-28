defmodule Nexus.PorfforAsyncFiberTest do
  @moduledoc """
  Proves the G3 cooperative-fiber handoff core (Nexus.Porffor.AsyncFiber) in isolation — the
  integration-independent mechanism that real await-suspension layers on. Fiber bodies are plain Elixir here
  (a wasm fiber body = a Washy instance invocation; `park` = the await host import; resume = a microtask), so
  this validates the protocol + ordering without the compiler wiring.
  """
  use ExUnit.Case, async: true

  alias Nexus.Porffor.AsyncFiber

  test "a fiber parks at each await and resumes in order; the caller continues past the async call" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    emit = fn s -> Agent.update(log, &[s | &1]) end

    body = fn ->
      emit.("A-enter")
      v1 = AsyncFiber.park(:await1)
      emit.("A-after1:#{v1}")
      v2 = AsyncFiber.park(:await2)
      emit.("A-after2:#{v2}")
      :a_done
    end

    # ── a mini event loop (this process = scheduler), mirroring node's order ──
    emit.("sync-start")
    # calling the async fn: run its body on a fiber until its first await; control returns here
    {:parked, fa} = AsyncFiber.spawn_fiber(body)
    emit.("sync-after-async")
    emit.("sync-end")

    # microtask queue: each resume runs as a microtask, re-scheduling if the fiber parks again
    queue = [{fa, 10}, {fa, 20}]
    drain = fn drain, q ->
      case q do
        [] ->
          :ok

        [{fiber, val} | rest] ->
          case AsyncFiber.resume(fiber, val) do
            {:parked, _} -> drain.(drain, rest)
            {:done, _result} -> drain.(drain, rest)
          end
      end
    end

    drain.(drain, queue)

    order = Agent.get(log, & &1) |> Enum.reverse()
    # The async body's continuations run AFTER the synchronous tail (true suspension), in order.
    assert order == [
             "sync-start",
             "A-enter",
             "sync-after-async",
             "sync-end",
             "A-after1:10",
             "A-after2:20"
           ]
  end

  test "spawn_fiber returns {:done, result} for a body that never parks" do
    assert {:done, 42} = AsyncFiber.spawn_fiber(fn -> 42 end)
  end

  test "a thrown fiber body surfaces as {:error, _}" do
    assert {:error, {:throw, :boom}} = AsyncFiber.spawn_fiber(fn -> throw(:boom) end)
  end

  # ── adversarial: a malicious/buggy fiber must never wedge the controller ──

  test "a fiber that is KILLED mid-run surfaces as {:error, :fiber_down} (controller never hangs)" do
    # Process.exit(self, :kill) bypasses the body's try/catch — models a fiber crash / fuel-kill mid-await.
    assert {:error, {:fiber_down, :killed}} =
             AsyncFiber.spawn_fiber(fn -> Process.exit(self(), :kill) end)
  end

  test "a fiber that never parks/completes is bounded by the handoff timeout, then killed" do
    # body neither parks, completes, nor crashes — it just blocks; the controller must not hang.
    assert {:error, :handoff_timeout} =
             AsyncFiber.spawn_fiber(fn -> Process.sleep(:infinity) end, timeout_ms: 50)
  end

  test "killing a parked fiber terminates it and demonitors (no leak)" do
    {:parked, fiber} = AsyncFiber.spawn_fiber(fn -> AsyncFiber.park(nil) end)
    assert Process.alive?(fiber.pid)
    assert :ok = AsyncFiber.kill(fiber)
    Process.sleep(10)
    refute Process.alive?(fiber.pid)
    # no stray :DOWN/handoff message left in the controller mailbox
    refute_received {:DOWN, _, _, _, _}
  end

  test "single-active is enforced: non-atomic shared counter sees no lost updates across handoff" do
    # Controller and fiber both do read-modify-write on the SAME :atomics cell with no atomic op and a yield
    # in the middle. If they ever ran concurrently, increments would be lost. The baton + blocking handoff
    # must serialize them, so after N rounds the counter == 2*N exactly. Repeat to shake out scheduler timing.
    for _ <- 1..200 do
      cell = :atomics.new(1, signed: false)

      bump = fn ->
        v = :atomics.get(cell, 1)
        :erlang.yield()
        :atomics.put(cell, 1, v + 1)
      end

      body = fn ->
        bump.()
        AsyncFiber.park(nil)
        bump.()
        :ok
      end

      {:parked, fiber} = AsyncFiber.spawn_fiber(body)
      bump.()
      {:done, :ok} = AsyncFiber.resume(fiber, nil)
      bump.()

      assert :atomics.get(cell, 1) == 4
    end
  end

  test "two fibers interleave under the scheduler (only one active at a time)" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    emit = fn s -> Agent.update(log, &[s | &1]) end

    mk = fn name ->
      fn ->
        emit.("#{name}-1")
        AsyncFiber.park(nil)
        emit.("#{name}-2")
        AsyncFiber.park(nil)
        emit.("#{name}-3")
        :ok
      end
    end

    {:parked, a} = AsyncFiber.spawn_fiber(mk.("A"))
    {:parked, b} = AsyncFiber.spawn_fiber(mk.("B"))
    # round-robin resume (FIFO microtask order)
    {:parked, a} = AsyncFiber.resume(a, nil)
    {:parked, b} = AsyncFiber.resume(b, nil)
    {:done, :ok} = AsyncFiber.resume(a, nil)
    {:done, :ok} = AsyncFiber.resume(b, nil)

    order = Agent.get(log, & &1) |> Enum.reverse()
    assert order == ["A-1", "B-1", "A-2", "B-2", "A-3", "B-3"]
  end
end

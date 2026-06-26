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

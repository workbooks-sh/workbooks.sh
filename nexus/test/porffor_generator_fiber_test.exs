defmodule Nexus.PorfforGeneratorFiberTest do
  @moduledoc """
  Proves the host-side generator driver (`Nexus.Porffor.GeneratorFiber`) — handle table, live-fiber cap, and
  kill-set registration — over the `AsyncFiber` handoff. Generator bodies are plain Elixir here (a real body
  adopts the Washy run context + invokes the generator's wasm func, calling `AsyncFiber.park` at each yield);
  this validates the driver + isolation requirements without the compiler/wasm wiring.
  """
  use ExUnit.Case, async: true

  alias Nexus.Porffor.{AsyncFiber, GeneratorFiber}

  # function* g(){ yield 1; yield 2; return :end }
  defp counting_body do
    fn ->
      AsyncFiber.park(1)
      AsyncFiber.park(2)
      :end
    end
  end

  test "drive a generator: spawn → first yield, resume → next yield, resume → done(return value)" do
    assert {:yield, h, 1} = GeneratorFiber.spawn(counting_body())
    assert {:yield, 2} = GeneratorFiber.resume(h, nil)
    assert {:done, :end} = GeneratorFiber.resume(h, nil)
  end

  test "two-way: .next(v) value becomes the result of the yield it resumes" do
    # function* g(){ var a = yield 1; var b = yield a + 10; return a + b }
    body = fn ->
      a = AsyncFiber.park(1)
      b = AsyncFiber.park(a + 10)
      a + b
    end

    assert {:yield, h, 1} = GeneratorFiber.spawn(body)
    assert {:yield, 110} = GeneratorFiber.resume(h, 100)
    assert {:done, 300} = GeneratorFiber.resume(h, 200)
  end

  test "a generator that never yields returns {:done, result} with no handle" do
    assert {:done, 42} = GeneratorFiber.spawn(fn -> 42 end)
    assert GeneratorFiber.live() == 0
  end

  test "resuming a finished generator's handle is an inert error (handle was freed)" do
    {:yield, h, 1} = GeneratorFiber.spawn(fn -> AsyncFiber.park(1) end)
    assert {:done, _} = GeneratorFiber.resume(h, nil)
    assert {:error, :unknown_generator_handle} = GeneratorFiber.resume(h, nil)
  end

  test "an unknown/forged handle is inert (process-local handle isolation)" do
    assert {:error, :unknown_generator_handle} = GeneratorFiber.resume(999_999, nil)
  end

  test "live-fiber CAP: a guest cannot spawn unbounded generators" do
    Process.put(:tl_gen_fiber_cap, 3)
    # three parked generators is fine
    for _ <- 1..3, do: assert({:yield, _h, _} = GeneratorFiber.spawn(fn -> AsyncFiber.park(0) end))
    assert GeneratorFiber.live() == 3
    # the fourth exceeds the cap
    assert_raise RuntimeError, ~r/cap exceeded/, fn ->
      GeneratorFiber.spawn(fn -> AsyncFiber.park(0) end)
    end
  end

  test "cap slot is released when a generator finishes, so new ones can spawn" do
    Process.put(:tl_gen_fiber_cap, 1)
    {:yield, h, 1} = GeneratorFiber.spawn(fn -> AsyncFiber.park(1) end)
    assert GeneratorFiber.live() == 1
    {:done, _} = GeneratorFiber.resume(h, nil)
    assert GeneratorFiber.live() == 0
    # cap slot freed → another generator can spawn
    assert {:yield, _h2, 1} = GeneratorFiber.spawn(fn -> AsyncFiber.park(1) end)
  end

  test "every generator fiber is registered in the run kill-set (:tl_thread_pids) for teardown reaping" do
    Process.delete(:tl_thread_pids)
    {:yield, _h, 1} = GeneratorFiber.spawn(fn -> AsyncFiber.park(1) end)
    pids = Process.get(:tl_thread_pids, [])
    assert length(pids) == 1
    assert Enum.all?(pids, &is_pid/1)
    # the registered pid is the live (parked) fiber process
    assert Enum.any?(pids, &Process.alive?/1)
  end

  test "close() kills a live generator, frees its handle and cap slot" do
    Process.put(:tl_gen_fiber_cap, 1024)
    {:yield, h, 1} = GeneratorFiber.spawn(fn -> AsyncFiber.park(1) end)
    before = GeneratorFiber.live()
    assert :ok = GeneratorFiber.close(h)
    assert GeneratorFiber.live() == before - 1
    assert {:error, :unknown_generator_handle} = GeneratorFiber.resume(h, nil)
    assert GeneratorFiber.close(h) == :ok
  end

  test "handles are process-local: a handle minted in one process is unknown in another" do
    parent = self()

    spawn(fn ->
      {:yield, h, 1} = GeneratorFiber.spawn(fn -> AsyncFiber.park(1) end)
      send(parent, {:handle, h})
    end)

    receive do
      {:handle, h} ->
        # `h` was minted in the spawned process's dict — inert here
        assert {:error, :unknown_generator_handle} = GeneratorFiber.resume(h, nil)
    after
      2000 -> flunk("no handle")
    end
  end
end

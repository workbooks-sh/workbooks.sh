defmodule Nexus.SandboxTrapTest do
  use ExUnit.Case, async: false

  # wb-qre6 — ADVERSARIAL proof that the wb-9jqy limits actually TRAP a hostile guest through the real
  # Nexus.Sandbox component lane (not just that the StoreLimits struct is shaped right). Fixtures are
  # WAT components built with wasm-tools: an infinite loop and an unbounded memory.grow loop.

  @trap_dir Path.join(__DIR__, "fixtures/trap")

  setup do
    # short epoch deadline so the trap fires fast; restore after.
    saved = Nexus.Config.sandbox_epoch_secs()
    Nexus.Config.put(:sandbox_epoch_secs, 1)
    on_exit(fn -> Nexus.Config.put(:sandbox_epoch_secs, saved) end)
    :ok
  end

  defp run_until_trap(wasm) do
    {:ok, pid} = Nexus.Sandbox.start(Path.join(@trap_dir, wasm), [])
    # the component GenServer is LINKED (start_link) — unlink so cleaning it up can't fell the test.
    Process.unlink(pid)
    t0 = System.monotonic_time(:millisecond)

    result =
      try do
        Nexus.Sandbox.call(pid, "run", [])
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end

    elapsed = System.monotonic_time(:millisecond) - t0
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    {result, elapsed}
  end

  test "an infinite-loop guest TRAPS at the epoch deadline (does not hang)" do
    {result, elapsed} = run_until_trap("spin.wasm")
    # the call returns an error (a trap), it does NOT run to the GenServer timeout / hang forever.
    assert match?({:error, _}, result), "expected a trap, got #{inspect(result)}"
    # trapped near the 1s deadline, well under the (secs+2)=3s GenServer timeout.
    assert elapsed < 3_000, "expected an epoch trap ~1s, took #{elapsed}ms (looks like a hang)"
  end

  test "an unbounded memory.grow guest TRAPS without OOMing the host" do
    mem_before = :erlang.memory(:total)
    {result, elapsed} = run_until_trap("grow.wasm")
    mem_after = :erlang.memory(:total)

    assert match?({:error, _}, result), "expected a trap, got #{inspect(result)}"
    assert elapsed < 3_000, "expected a trap ~1s, took #{elapsed}ms"
    # the StoreLimits memory cap held: the BEAM total didn't balloon by the unbounded growth.
    assert mem_after - mem_before < 512 * 1024 * 1024,
           "BEAM grew #{div(mem_after - mem_before, 1024 * 1024)}MB — memory cap did not hold"
  end
end

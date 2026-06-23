defmodule Nexus.CellTest do
  @moduledoc """
  The Cell (wb-qgpz) — one supervised process owning an agent's execution context (/work + grant +
  optional session + optional membrane bridge), with bundled lifecycle + teardown. The wasmer-backed
  behaviours run only when wasmer is present; the supervision/lifecycle parts always run.
  """
  use ExUnit.Case, async: false

  test "a cell starts supervised, exposes perms + stats, and stops cleanly" do
    {:ok, cell} = Nexus.Cell.start(grant: ["fs", "exec"], tenant: "t1")
    assert is_pid(cell)
    assert %{grant: ["fs", "exec"], tenant: "t1"} = Nexus.Cell.perms(cell)
    assert %{runs: 0, tenant: "t1"} = Nexus.Cell.stats(cell)
    ref = Process.monitor(cell)
    :ok = Nexus.Cell.stop(cell)
    assert_receive {:DOWN, ^ref, :process, ^cell, _}, 2_000
  end

  @tag :wasmer
  test "a stateful + bridged cell runs commands, persists state, and meters runs" do
    if Nexus.Wasmer.available?() do
      {:ok, cell} = Nexus.Cell.start(grant: ["fs", "exec"], stateful: true, bridge: true)

      # the cell's perms carry the session + membrane it owns
      perms = Nexus.Cell.perms(cell)
      assert is_pid(perms[:session])
      assert %{port: _, token: _} = perms[:membrane]

      Nexus.Cell.run(cell, "echo hi > /work/a.txt")
      assert Nexus.Cell.run(cell, "cat /work/a.txt") |> String.trim() == "hi"
      assert %{runs: 2} = Nexus.Cell.stats(cell)

      # teardown stops the owned session + socket
      session = perms[:session]
      Nexus.Cell.stop(cell)
      Process.sleep(100)
      refute Process.alive?(session)
    else
      IO.puts("\n[skip] wasmer absent")
    end
  end
end

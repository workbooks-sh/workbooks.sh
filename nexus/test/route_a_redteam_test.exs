defmodule Nexus.RouteARedteamTest do
  @moduledoc """
  wb-vhq1u Step 5 (parity + red-team): the route-(a) TL seam must contain a malicious guest exactly like
  the wasmex sandbox it replaces — a runaway core cannot harm the host. Capability confinement (ungranted
  cap → trap, tenant partitioning) is covered by `TinyLasers.Wasm.HostDock`'s own suite; this covers the
  RESOURCE bounds (CPU/memory) on the `Nexus.Compile.c_unit_core` → `TinyLasers.Wasm` path.
  """
  use ExUnit.Case, async: false

  defp core(name, body) do
    {:ok, path, _} = Nexus.Compile.c_unit_core(%{name: name, body: body})
    {:ok, mod} = TinyLasers.Wasm.decode(File.read!(path))
    mod
  end

  defp contained?(result), do: match?({:timeout}, result) or match?({:killed, _}, result)

  @tag timeout: 120_000
  test "infinite spin is killed by TL's wall-clock bound; the host survives" do
    mod = core("spin", "int spin(void){volatile long i=0;while(1){i++;} return 0;}")

    result =
      TinyLasers.Gate.bounded(fn -> TinyLasers.Wasm.call_io(mod, "spin", [], []) end,
        timeout: 3_000,
        max_heap_size: 268_435_456
      )

    assert contained?(result), "spin escaped containment: #{inspect(result)}"
    assert Process.alive?(self())
  end

  @tag timeout: 120_000
  test "unbounded allocation is contained; the host survives" do
    mod =
      core("bomb", "int bomb(void){static char b[100000000]; for(long i=0;i<100000000;i++) b[i]=(char)i; return b[99999999];}")

    result =
      TinyLasers.Gate.bounded(fn -> TinyLasers.Wasm.call_io(mod, "bomb", [], []) end,
        timeout: 5_000,
        max_heap_size: 67_108_864
      )

    assert contained?(result), "alloc bomb escaped containment: #{inspect(result)}"
    assert Process.alive?(self())
  end
end

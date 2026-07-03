defmodule Nexus.CompileCoreTest do
  @moduledoc """
  wb-vhq1u Step 2 (route a): a `c` unit compiled to a CORE wasm32-wasip1 module reaches a Dock cap through
  the ONE `host_call` import, runs on `TinyLasers.Wasm` — no WIT component, no componentize, no wasmex.
  The BEAM-native replacement for the `Nexus.Sandbox.start`/component path (wb-4z3fv).
  """
  use ExUnit.Case, async: false
  alias TinyLasers.Wasm

  @tag timeout: 120_000
  test "route (a): C guest → core + host_call → HostDock → Dock.now, on TinyLasers.Wasm" do
    # A C reactor unit that calls the ambient `now` Dock cap via the typed host_call ABI and returns it.
    node = %{
      name: "stamper",
      body: """
      long stamp(void) {
        char out[64];
        int rl = host_call("dock_now", 8, "[]", 2, out, 64);
        long v = 0;
        for (int i = 0; i < rl; i++) if (out[i] >= '0' && out[i] <= '9') v = v * 10 + (out[i] - '0');
        return v;
      }
      """
    }

    assert {:ok, core_path, ["stamp"]} = Nexus.Compile.c_unit_core(node)
    {:ok, mod} = Wasm.decode(File.read!(core_path))

    # THE contract check: exactly ONE host import — host_call. No component, no WIT world.
    assert Enum.map(mod.imports, fn {_m, n, _t} -> n end) == ["host_call"]

    before = System.os_time(:second)

    {:completed, {ts, _out}} =
      TinyLasers.Gate.bounded(
        fn ->
          # the run context the flip (Step 4) plants; set here since a bounded run is a fresh process
          Process.put(:dock_tenant, "core-test-tenant")
          Process.put(:dock_caps, :all)

          Wasm.call_io(mod, "stamp", [], [])
        end,
        timeout: 60_000,
        max_heap_size: 268_435_456
      )

    # the guest got a REAL host timestamp back through the bridge → the cap round-trip works end to end
    assert ts >= before - 5 and ts <= System.os_time(:second) + 5
  end
end

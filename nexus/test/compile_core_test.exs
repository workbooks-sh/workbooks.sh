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

    assert {:ok, core_path, exports, _str} = Nexus.Compile.c_unit_core(node)
    assert "stamp" in exports
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

  @tag timeout: 120_000
  test "route (a): string caps — store + load round-trip through generated host_call wrappers" do
    node = %{
      name: "kvcheck",
      header: "grant: [store, load]",
      body: """
      int check(void) {
        store("k", 1, "hello", 5);
        nx_str v = load("k", 1);
        if (v.len != 5) return 0;
        const char* e = "hello";
        for (int i = 0; i < 5; i++) if (v.ptr[i] != e[i]) return 0;
        return 1;
      }
      """
    }

    assert {:ok, core_path, exports, _str} = Nexus.Compile.c_unit_core(node)
    assert "check" in exports
    {:ok, mod} = Wasm.decode(File.read!(core_path))
    assert Enum.map(mod.imports, fn {_m, n, _t} -> n end) == ["host_call"]

    {:completed, {result, _out}} =
      TinyLasers.Gate.bounded(
        fn ->
          Process.put(:dock_tenant, "core-kv-tenant")
          # runtime gate uses grant WORDS: "kv" unlocks store/load (Dock @cap_grants) — nothing else
          Process.put(:dock_caps, ["kv"])
          Wasm.call_io(mod, "check", [], [])
        end,
        timeout: 60_000,
        max_heap_size: 268_435_456
      )

    # 1 = the guest stored "hello", loaded it back, and the bytes matched — both marshaling directions work
    assert result == 1
  end

  @tag timeout: 120_000
  test "Step 4 wiring: dock context rides Nexus.Wasm.Sandbox.run's ctx snapshot into the isolated run" do
    node = %{
      name: "stamper2",
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

    {:ok, core_path, _, _str} = Nexus.Compile.c_unit_core(node)
    {:ok, mod} = Wasm.decode(File.read!(core_path))

    # set the dock context in the CALLER's dict — Nexus.Wasm.Sandbox.run must snapshot it into the run
    # process (this is exactly what the ssr.ex:667 flip relies on)
    Process.put(:dock_tenant, "prod-path-tenant")
    Process.put(:dock_caps, :all)
    before = System.os_time(:second)

    assert {:ok, ts, _out, _meta} = Nexus.Wasm.Sandbox.run(mod, "stamp", [])
    assert ts >= before - 5 and ts <= System.os_time(:second) + 5
  end

  @tag timeout: 180_000
  test "route (a): a GO unit (tinygo → core) reaches Dock caps via generated hostCall wrappers" do
    node = %{
      name: "gokv",
      header: "grant: [store, load]",
      body: """
      //go:wasmexport check
      func check() int32 {
      	store("k", "hello")
      	if load("k") == "hello" {
      		return 1
      	}
      	return 0
      }
      """
    }

    assert {:ok, core_path, ["check"], _} = Nexus.Compile.go_unit_core(node)
    {:ok, mod} = Wasm.decode(File.read!(core_path))
    # the ONE host import is host_call (tinygo also imports wasi builtins; assert host_call is present)
    assert "host_call" in Enum.map(mod.imports, fn {_m, n, _t} -> n end)

    {:completed, result} =
      TinyLasers.Gate.bounded(
        fn ->
          Process.put(:dock_tenant, "go-kv-tenant")
          Process.put(:dock_caps, ["kv"])
          # tinygo emits a reactor runtime (GC/globals) — MUST run _initialize before any export
          {:ok, inst, _out} = Wasm.instance_start(mod, "_initialize", [])
          {:ok, v, _out, _inst} = Wasm.instance_invoke(inst, "check", [])
          v
        end,
        timeout: 90_000,
        max_heap_size: 268_435_456
      )

    assert result == 1
  end

  @tag timeout: 120_000
  test "route (a) §5b: tl_alloc gives stable, non-overlapping guest memory (string-return foundation)" do
    node = %{
      name: "alloctest",
      body: """
      int alloc_check(void) {
        char *p = tl_alloc(5);
        p[0]='h'; p[1]='e'; p[2]='l'; p[3]='l'; p[4]='o';
        char *q = tl_alloc(3);
        q[0]='x'; q[1]='y'; q[2]='z';
        // p must survive the second alloc (stable) and not overlap q
        return (p[0]=='h' && p[4]=='o' && q[0]=='x' && p != q) ? 1 : 0;
      }
      """
    }

    assert {:ok, core_path, exports, _str} = Nexus.Compile.c_unit_core(node)
    assert "tl_alloc" in exports
    {:ok, mod} = Wasm.decode(File.read!(core_path))

    {:completed, {v, _out}} =
      TinyLasers.Gate.bounded(fn -> Wasm.call_io(mod, "alloc_check", [], []) end,
        timeout: 60_000,
        max_heap_size: 268_435_456
      )

    assert v == 1
  end

  @tag timeout: 120_000
  test "route (a) §5b: a string-RETURNING C export round-trips via run_str (packed-i64 + tl_alloc)" do
    node = %{
      name: "greeter",
      body: """
      long long greet(void) {
        char *p = tl_alloc(5);
        p[0]='h'; p[1]='e'; p[2]='l'; p[3]='l'; p[4]='o';
        unsigned int addr = (unsigned int)p;
        return ((long long)addr << 32) | 5LL;
      }
      """
    }

    assert {:ok, core_path, exports, _str} = Nexus.Compile.c_unit_core(node)
    assert "greet" in exports
    {:ok, mod} = Wasm.decode(File.read!(core_path))

    # run_str instantiates, invokes greet → packed (ptr<<32)|len, reads the string from guest mem
    assert {:ok, "hello"} = Nexus.Wasm.Sandbox.run_str(mod, "greet", [])
  end

  @tag timeout: 120_000
  test "route (a) §5b marker: a nx_str-returning `render` is rewritten to a packed export + marked" do
    # the natural authoring API — the author just returns nx_str; c_unit_core wraps it (§5b marker).
    node = %{
      name: "greeter2",
      body: """
      nx_str render(void) {
        char *p = tl_alloc(5);
        p[0]='w'; p[1]='o'; p[2]='r'; p[3]='l'; p[4]='d';
        return (nx_str){p, 5};
      }
      """
    }

    assert {:ok, core_path, exports, str_exports} = Nexus.Compile.c_unit_core(node)
    assert "render" in exports
    # THE marker: render is flagged string-returning so the run path picks run_str, not run
    assert "render" in str_exports
    {:ok, mod} = Wasm.decode(File.read!(core_path))

    assert {:ok, "world"} = Nexus.Wasm.Sandbox.run_str(mod, "render", [])
  end
end

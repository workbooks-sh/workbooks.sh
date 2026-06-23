defmodule Nexus.WashyTest do
  @moduledoc """
  Washy spike — a wasm interpreter in PURE ELIXIR. Milestone 1: decode a real wasm binary + run integer
  arithmetic and a function-calling-a-function, executed entirely on the BEAM (no NIF, no native runtime).
  Also shows the isolation payoff: a trap is a caught exception in one process, never a VM crash.
  """
  use ExUnit.Case, async: true

  # hand-encoded wasm module: func0 add(i32,i32)->i32 ; func1 dbl(i32)->i32 = add(x,x)
  @mod <<
    0, 97, 115, 109, 1, 0, 0, 0,
    # type: (i32,i32)->i32 ; (i32)->i32
    1, 12, 2, 96, 2, 127, 127, 1, 127, 96, 1, 127, 1, 127,
    # function: func0:type0, func1:type1
    3, 3, 2, 0, 1,
    # export: "add"->0, "dbl"->1
    7, 13, 2, 3, 97, 100, 100, 0, 0, 3, 100, 98, 108, 0, 1,
    # code: add = local.get 0; local.get 1; i32.add ; dbl = local.get 0; local.get 0; call 0
    10, 18, 2, 7, 0, 32, 0, 32, 1, 106, 11, 8, 0, 32, 0, 32, 0, 16, 0, 11
  >>

  test "decode + run integer arithmetic in pure Elixir" do
    {:ok, mod} = Nexus.Washy.decode(@mod)
    assert Nexus.Washy.call(mod, "add", [3, 4]) == 7
    assert Nexus.Washy.call(mod, "add", [100, 23]) == 123
  end

  test "a function calling another function (call opcode)" do
    {:ok, mod} = Nexus.Washy.decode(@mod)
    assert Nexus.Washy.call(mod, "dbl", [5]) == 10
    assert Nexus.Washy.call(mod, "dbl", [21]) == 42
  end

  test "i32 add wraps at 32 bits (real wasm semantics)" do
    {:ok, mod} = Nexus.Washy.decode(@mod)
    assert Nexus.Washy.call(mod, "add", [0xFFFFFFFF, 1]) == 0
  end

  # module with 1 page of memory; memtest() stores 42 at addr 100 then loads it back -> 42.
  # NB: i32.const 100 is signed-LEB `0xE4 0x00` (a bare 0x64 would decode as -28 — bit 6 is the sign bit).
  @memmod <<
    0, 97, 115, 109, 1, 0, 0, 0,
    1, 5, 1, 96, 0, 1, 127,
    3, 2, 1, 0,
    5, 3, 1, 0, 1,
    7, 11, 1, 7, 109, 101, 109, 116, 101, 115, 116, 0, 0,
    10, 18, 1, 16, 0, 65, 228, 0, 65, 42, 54, 0, 0, 65, 228, 0, 40, 0, 0, 11
  >>

  test "linear memory (:atomics) — store then load roundtrips in pure Elixir" do
    {:ok, mod} = Nexus.Washy.decode(@memmod)
    assert Nexus.Washy.call(mod, "memtest", []) == 42
  end

  test "BEAM isolation: a trap is a caught exception in ONE process, not a VM crash" do
    # a body with an unimplemented opcode raises — but the test VM keeps running, proving fault isolation.
    bad = <<0, 97, 115, 109, 1, 0, 0, 0,
            1, 5, 1, 96, 0, 1, 127,
            3, 2, 1, 0,
            7, 7, 1, 3, 98, 97, 100, 0, 0,
            10, 5, 1, 3, 0, 0xD3, 11>>
    {:ok, mod} = Nexus.Washy.decode(bad)
    parent = self()
    # run it in its OWN process; the crash stays there
    pid = spawn(fn -> send(parent, {:result, (try do Nexus.Washy.call(mod, "bad", []) rescue e -> {:trapped, Exception.message(e)} end)}) end)
    ref = Process.monitor(pid)
    assert_receive {:result, {:trapped, msg}}, 1000
    assert msg =~ "unimplemented opcode"
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    # the test process is alive and well — the trap did not take down the VM
    assert Process.alive?(self())
  end
end

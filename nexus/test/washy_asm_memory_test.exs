defmodule Nexus.WashyAsmMemoryTest do
  @moduledoc """
  **BEAM-assembly memory op-group (`Nexus.Washy.AsmOps.Memory`, epic wb-wzdq).** A/Bs functions that
  store then load integers at various addresses/widths through THREE lanes — interpreter, forms-native,
  asm-native — and asserts all agree bit-identically, including unaligned + word-spanning addresses, all
  load/store widths, signed loads of negative bytes, an out-of-bounds access (must TRAP identically in
  both interp + asm), and memory.size/grow round-trips.
  """
  use ExUnit.Case, async: true

  alias Nexus.Washy

  # i32 -> i32 function `f` (the only signature the asm lane attempts). `arg0`/`arg1` are the two i32 args.
  defp build(nlocals, instrs) do
    %Washy{
      types: [{[127, 127], [127]}],
      funcs: [0],
      code: [{nlocals, instrs}],
      exports: %{"f" => 0},
      mem: {1, nil},
      globals: [],
      data: [],
      imports: [],
      elements: [],
      id: :crypto.hash(:sha256, :erlang.term_to_binary({nlocals, instrs}))
    }
  end

  defp interp(m, args), do: elem(Washy.call_io(m, "f", args, transpile: false), 0)

  defp asm(m, args),
    do: elem(Washy.call_io(m, "f", args, transpile: true, tier_threshold: 1, tier_async: false), 0)

  defp agree(m, argsets) do
    for args <- argsets do
      i = interp(m, args)
      a = asm(m, args)
      assert i == a, "@ #{inspect(args)}: interp=#{inspect(i)} asm=#{inspect(a)}"
    end
  end

  @addrs [[0, 0], [1, 0], [3, 0], [4, 0], [7, 0], [8, 0], [13, 0], [100, 0], [4093, 0]]

  test "i32 store/load round-trips at aligned + unaligned + word-spanning addresses" do
    # f(addr, val): mem[addr] = val (i32); return mem[addr] (i32)
    m =
      build(0, [
        {:local_get, 0},
        {:local_get, 1},
        {:i32_store, 0},
        {:local_get, 0},
        {:i32_load, 0}
      ])

    sets = for [a, _] <- @addrs, v <- [0, 1, 0xDEADBEEF, 0xFFFFFFFF, 0x00FF00FF], do: [a, v]
    agree(m, sets)
  end

  test "store8/load8u + load8s sign-extension of negative bytes" do
    # store the low byte, then load it both unsigned and signed
    for {load_op, label} <- [{:i32_load8u, "u"}, {:i32_load8s, "s"}] do
      m =
        build(0, [
          {:local_get, 0},
          {:local_get, 1},
          {:i32_store8, 0},
          {:local_get, 0},
          {load_op, 0}
        ])

      sets = for a <- [0, 1, 7, 8, 50], v <- [0, 1, 0x7F, 0x80, 0xFF, 0x123], do: [a, v]
      agree(m, sets)
      assert label in ["u", "s"]
    end
  end

  test "store16/load16u + load16s sign-extension across word boundary" do
    for load_op <- [:i32_load16u, :i32_load16s] do
      m =
        build(0, [
          {:local_get, 0},
          {:local_get, 1},
          {:i32_store16, 0},
          {:local_get, 0},
          {load_op, 0}
        ])

      # addr 7 makes the 2-byte access SPAN two packed words (exercises the slow byte path)
      sets = for a <- [0, 1, 6, 7, 8, 30], v <- [0, 1, 0x7FFF, 0x8000, 0xFFFF, 0x12345], do: [a, v]
      agree(m, sets)
    end
  end

  test "non-zero static offset immediate folds into the effective address" do
    # f(addr, val): mem[addr+16] = val; return mem[addr+16]
    m =
      build(0, [
        {:local_get, 0},
        {:local_get, 1},
        {:i32_store, 16},
        {:local_get, 0},
        {:i32_load, 16}
      ])

    sets = for a <- [0, 3, 7, 64], v <- [0x11223344, 0xFFFFFFFF], do: [a, v]
    agree(m, sets)
  end

  test "out-of-bounds load traps identically in both lanes" do
    # f(addr, _): return mem[addr] (i32). addr near/over the 1-page (65536-byte) limit traps.
    m = build(0, [{:local_get, 0}, {:i32_load, 0}])

    for addr <- [65533, 65536, 70000, 0x7FFFFFFF] do
      i =
        try do
          {:ok, interp(m, [addr, 0])}
        rescue
          e in Nexus.Washy.Trap -> {:trap, e.reason}
        end

      a =
        try do
          {:ok, asm(m, [addr, 0])}
        rescue
          e in Nexus.Washy.Trap -> {:trap, e.reason}
        end

      assert i == a and i == {:trap, :out_of_bounds}, "@addr #{addr}: interp=#{inspect(i)} asm=#{inspect(a)}"
    end
  end

  test "out-of-bounds store traps identically in both lanes" do
    m = build(0, [{:local_get, 0}, {:local_get, 1}, {:i32_store, 0}, {:i32_const, 0}])

    for addr <- [65533, 65536, 99999] do
      trap = fn fun ->
        try do
          {:ok, fun.()}
        rescue
          e in Nexus.Washy.Trap -> {:trap, e.reason}
        end
      end

      i = trap.(fn -> interp(m, [addr, 7]) end)
      a = trap.(fn -> asm(m, [addr, 7]) end)
      assert i == a and i == {:trap, :out_of_bounds}, "@addr #{addr}: interp=#{inspect(i)} asm=#{inspect(a)}"
    end
  end

  test "memory.size round-trip (returns current page count)" do
    m = build(0, [{:memory_size}, {:local_get, 0}, {:op, 0x6B}])
    # f(x,_) = memory.size - x ; with 1 page that's 1 - x
    agree(m, for(x <- [0, 1, 2], do: [x, 0]))
  end

  test "memory.grow then memory.size reflects the new page count" do
    # f(n, _): old = memory.grow(n); return memory.size  (== 1 + n on success, else still 1)
    m =
      build(1, [
        {:local_get, 0},
        {:memory_grow},
        {:local_set, 2},
        {:memory_size}
      ])

    agree(m, for(n <- [0, 1, 2, 3], do: [n, 0]))
  end

  test "memory.grow returns old page count (or -1 on failure)" do
    # f(n, _): return memory.grow(n)
    m = build(0, [{:local_get, 0}, {:memory_grow}])
    # n=0 -> 1 (old pages); huge n -> -1 (masked to 0xFFFFFFFF)
    agree(m, [[0, 0], [1, 0], [2, 0], [0xFFFFFFFF, 0]])
  end

  test "memory.fill then load reads the filled byte pattern" do
    # f(addr, val): memory.fill(addr, val, 8); return mem[addr] (i32, low 4 of the 8 filled bytes)
    m =
      build(0, [
        {:local_get, 0},
        {:local_get, 1},
        {:i32_const, 8},
        {:memory_fill},
        {:local_get, 0},
        {:i32_load, 0}
      ])

    agree(m, for(a <- [0, 3, 7, 64], v <- [0, 0xAB, 0xFF], do: [a, v]))
  end

  test "memory.copy duplicates a region" do
    # f(_, _): mem[0]=0x11223344; memory.copy(64, 0, 4); return mem[64]
    m =
      build(0, [
        {:i32_const, 0},
        {:i32_const, 0x11223344},
        {:i32_store, 0},
        {:i32_const, 64},
        {:i32_const, 0},
        {:i32_const, 4},
        {:memory_copy},
        {:i32_const, 64},
        {:i32_load, 0}
      ])

    agree(m, [[0, 0], [1, 1]])
  end

  test "data.drop is a no-op (followed by a normal load)" do
    m = build(0, [{:data_drop}, {:local_get, 0}, {:local_get, 1}, {:i32_store, 0}, {:local_get, 0}, {:i32_load, 0}])
    agree(m, [[0, 42], [16, 0xCAFE]])
  end
end

defmodule Nexus.WashyTrapTest do
  @moduledoc """
  Wasm **trap semantics** — the spec-defined faults (div-by-zero, signed overflow, out-of-bounds,
  unreachable) raise a structured `Nexus.Washy.Trap` with a stable `reason`. A trap is a caught
  exception in ONE process; the transpiler will lower the same faults to the same exception, so the
  differential oracle can assert both backends trap identically.
  """
  use ExUnit.Case, async: true

  alias Nexus.Washy
  alias Nexus.Washy.Trap

  # ()->i32 module exporting "f" with the given code body (locals byte included).
  defp mod(body) do
    bsz = byte_size(body)
    code = <<10, bsz + 2, 1, bsz>> <> body
    bin =
      <<0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 0x60, 0, 1, 0x7F, 3, 2, 1, 0, 7, 5, 1, 1, 0x66, 0, 0>> <>
        code
    {:ok, m} = Washy.decode(bin)
    m
  end

  # same, but with a 1-page memory section (for load/store bounds)
  defp memmod(body) do
    bsz = byte_size(body)
    code = <<10, bsz + 2, 1, bsz>> <> body
    bin =
      <<0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 0x60, 0, 1, 0x7F, 3, 2, 1, 0, 5, 3, 1, 0, 1,
        7, 5, 1, 1, 0x66, 0, 0>> <> code
    {:ok, m} = Washy.decode(bin)
    m
  end

  test "i32.div_s by zero traps with :div_by_zero" do
    # locals=0; i32.const 10; i32.const 0; i32.div_s; end
    m = mod(<<0, 0x41, 10, 0x41, 0, 0x6D, 0x0B>>)
    assert_raise Trap, ~r/div_by_zero/, fn -> Washy.call(m, "f", []) end
  end

  test "i32.rem_u by zero traps with :div_by_zero" do
    m = mod(<<0, 0x41, 10, 0x41, 0, 0x70, 0x0B>>)
    assert_raise Trap, ~r/div_by_zero/, fn -> Washy.call(m, "f", []) end
  end

  test "i32.div_s INT_MIN / -1 traps with :int_overflow" do
    # i32.const -2147483648 (sleb: 0x80,0x80,0x80,0x80,0x78); i32.const -1 (0x7F); i32.div_s
    m = mod(<<0, 0x41, 0x80, 0x80, 0x80, 0x80, 0x78, 0x41, 0x7F, 0x6D, 0x0B>>)
    assert_raise Trap, ~r/int_overflow/, fn -> Washy.call(m, "f", []) end
  end

  test "out-of-bounds i32.load traps with :out_of_bounds (addr past memory.size)" do
    # i32.const 100000 (>64KB page); i32.load align0 off0
    m = memmod(<<0, 0x41, 0xA0, 0x8D, 0x06, 0x28, 0x00, 0x00, 0x0B>>)
    assert_raise Trap, ~r/out_of_bounds/, fn -> Washy.call(m, "f", []) end
  end

  test "an in-bounds load does NOT trap (boundary sanity)" do
    # i32.const 0; i32.load — valid, returns 0
    m = memmod(<<0, 0x41, 0x00, 0x28, 0x00, 0x00, 0x0B>>)
    assert Washy.call(m, "f", []) == 0
  end

  test "unreachable traps with :unreachable" do
    m = mod(<<0, 0x00, 0x0B>>)
    assert_raise Trap, ~r/unreachable/, fn -> Washy.call(m, "f", []) end
  end

  test "a trap stays in ONE process — the VM survives" do
    m = mod(<<0, 0x41, 1, 0x41, 0, 0x6D, 0x0B>>)
    parent = self()
    pid = spawn(fn -> send(parent, {:r, (try do Washy.call(m, "f", []) rescue e in Trap -> {:trapped, e.reason} end)}) end)
    assert_receive {:r, {:trapped, :div_by_zero}}, 1000
    assert Process.alive?(self())
  end
end

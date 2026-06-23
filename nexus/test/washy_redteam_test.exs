defmodule Nexus.WashyRedteamTest do
  @moduledoc """
  Phase A safety gate (wb-yre2): hostile modules must be CONTAINED — bounded by fuel, wall-clock,
  call-depth, and memory — with no VM crash and no host escape. A trap stays in one process; the
  test VM and the caller survive every case.
  """
  use ExUnit.Case, async: true

  alias Nexus.Washy
  alias Nexus.Washy.Sandbox

  # ── module builders (hand-encoded wasm) ───────────────────────────────────────────────────────
  # ()->() function "f" with the given body bytes (locals byte included), optional 1-page memory.
  defp build(body, mem? \\ false) do
    bsz = byte_size(body)
    code = <<10, bsz + 2, 1, bsz>> <> body
    memsec = if mem?, do: <<5, 3, 1, 0, 1>>, else: <<>>
    bin =
      <<0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 0x60, 0, 0, 3, 2, 1, 0>> <>
        memsec <> <<7, 5, 1, 1, 0x66, 0, 0>> <> code
    {:ok, m} = Washy.decode(bin)
    m
  end

  test "infinite loop is bounded by FUEL (traps :out_of_fuel, no hang)" do
    # loop { br 0 }  — spins forever without fuel
    m = build(<<0, 0x03, 0x40, 0x0C, 0x00, 0x0B, 0x0B>>)
    assert_raise Washy.Trap, ~r/out_of_fuel/, fn -> Washy.call(m, "f", [], fuel: 100_000) end
  end

  test "infinite loop is bounded by WALL-CLOCK via the sandbox (brutal_kill -> :timeout)" do
    m = build(<<0, 0x03, 0x40, 0x0C, 0x00, 0x0B, 0x0B>>)
    # huge fuel so only the timer can stop it; sandbox kills the process
    assert {:timeout} = Sandbox.run(m, "f", [], fuel: 1_000_000_000_000, timeout_ms: 150)
    assert Process.alive?(self())
  end

  test "unbounded recursion is bounded by CALL-DEPTH (traps :stack_exhausted, no process crash)" do
    # func "f" calls itself: call 0 (global func idx 0). recurse forever.
    m = build(<<0, 0x10, 0x00, 0x0B>>)
    assert_raise Washy.Trap, ~r/stack_exhausted/, fn -> Washy.call(m, "f", [], max_depth: 500) end
  end

  test "huge memory.grow is REJECTED (capped, returns -1, no OOM)" do
    # memory.grow with 1,000,000 pages (≈64GB) must fail → -1, not allocate
    # i32.const 1000000 ; memory.grow ; drop
    m = build(<<0, 0x41, 0xC0, 0x84, 0x3D, 0x40, 0x00, 0x1A, 0x0B>>, true)
    assert Washy.call(m, "f", []) == nil
    assert Process.alive?(self())
  end

  test "out-of-bounds write traps, does not corrupt host (sandbox contains it)" do
    # i32.const 100000 ; i32.const 1 ; i32.store  (addr past the single page)
    m = build(<<0, 0x41, 0xA0, 0x8D, 0x06, 0x41, 1, 0x36, 0x00, 0x00, 0x0B>>, true)
    assert {:trap, :out_of_bounds} = Sandbox.run(m, "f", [])
    assert Process.alive?(self())
  end

  test "the sandbox runs a benign module to completion with bounds in place" do
    # i32.const 1 ; drop   (valid no-op)
    m = build(<<0, 0x41, 1, 0x1A, 0x0B>>)
    assert {:ok, _r, "", %{truncated?: false}} = Sandbox.run(m, "f", [])
  end

  test "a trap inside the sandbox is reported, not raised at the caller" do
    m = build(<<0, 0x00, 0x0B>>)
    assert {:trap, :unreachable} = Sandbox.run(m, "f", [])
    assert Process.alive?(self())
  end

  test "valid programs still run unchanged under the default fuel budget" do
    # sanity: the fuel tax doesn't break normal execution
    sumto = <<0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 127, 1, 127, 3, 2, 1, 0,
              7, 9, 1, 5, 115, 117, 109, 116, 111, 0, 0,
              10, 35, 1, 33, 1, 1, 127, 2, 64, 3, 64, 32, 0, 69, 13, 1, 32, 1, 32, 0, 106, 33, 1,
              32, 0, 65, 1, 107, 33, 0, 12, 0, 11, 11, 32, 1, 11>>
    {:ok, m} = Washy.decode(sumto)
    assert Washy.call(m, "sumto", [100]) == 5050
  end
end

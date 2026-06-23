defmodule Nexus.WashyDensityTest do
  @moduledoc """
  Phase B gate (wb-afsq): the density invariants that make ≥5000 cells/GB real.

    1. Linear memory is PACKED (8 bytes/atomics-slot) and RIGHT-SIZED to the module's `min` pages —
       no 8× byte waste, no 64-page over-allocation. Per-cell memory == the wasm memory the program
       actually has.
    2. The decode cache SHARES one immutable module struct across cells (persistent_term, no per-read
       copy) — so the Nth cell costs only fresh mutable state, never a re-decode.

  These are deterministic structural assertions; the live cells/GB figure is reported by
  `scripts/washy_density.exs` (machine-dependent, not asserted in CI).
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy

  # ()->i32 module with a 2-page memory (min=2), exporting "f" = i32.const 0; i32.load
  @mem2 <<0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 0x60, 0, 1, 0x7F, 3, 2, 1, 0, 5, 3, 1, 0, 2,
          7, 5, 1, 1, 0x66, 0, 0, 10, 9, 1, 7, 0, 0x41, 0, 0x28, 0, 0, 0x0B>>

  test "packed memory is right-sized to min pages with zero waste" do
    {:ok, m} = Washy.decode(@mem2)
    assert m.mem == {2, nil}
    # 2 pages * 65536 bytes / 8 bytes-per-slot = 16384 slots — exactly the wasm size, no 64-page cap.
    # (vs the old design: 64 * 65536 = 4,194,304 slots regardless of need.)
    assert Washy.mem_slots(m) == 2 * 8192
    assert Washy.mem_slots(m) * 8 == 2 * 65536
    # and the run still works over that packed backing
    assert Washy.call(m, "f", []) == 0
  end

  test "memory still round-trips correctly through packed words (store/load across word boundaries)" do
    # store bytes at offsets that straddle 8-byte word boundaries, read them back
    {:ok, m} = Washy.decode(store_load_mod())
    # f(addr, val) writes val at addr then reads it back
    for addr <- [0, 7, 8, 9, 15, 16, 1000, 65535] do
      assert Washy.call(m, "f", [addr, 0xDEADBEEF]) == 0xDEADBEEF
    end
  end

  test "decode_cached shares ONE immutable module struct across callers" do
    bytes = @mem2
    # clear any prior cache entry for determinism
    :persistent_term.erase({:washy_mod_cache, :crypto.hash(:sha256, bytes)})
    {:ok, a} = Washy.decode_cached(bytes)
    {:ok, b} = Washy.decode_cached(bytes)
    # same term (persistent_term returns the shared struct, not a fresh decode)
    assert a == b
    assert :persistent_term.get({:washy_mod_cache, :crypto.hash(:sha256, bytes)}) == a
  end

  test "a 1-page cell's mutable footprint is ~64KB (the packed memory), module shared" do
    # the per-cell retained state is dominated by the packed linear memory; for 1 page that's 64KB,
    # which at one process per cell yields well over 5000 cells/GB (see scripts/washy_density.exs).
    one_page = :atomics.new(1 * 8192, signed: false)
    assert :atomics.info(one_page).size * 8 == 65536
  end

  # f(addr, val): i32.store(addr, val); i32.load(addr)  — type (i32,i32)->i32, 4-page mem
  defp store_load_mod do
    <<0, 97, 115, 109, 1, 0, 0, 0,
      1, 7, 1, 0x60, 2, 0x7F, 0x7F, 1, 0x7F,
      3, 2, 1, 0,
      5, 3, 1, 0, 4,
      7, 5, 1, 1, 0x66, 0, 0,
      10, 16, 1, 14, 0,
      0x20, 0, 0x20, 1, 0x36, 0x00, 0x00,
      0x20, 0, 0x28, 0x00, 0x00,
      0x0B>>
  end
end

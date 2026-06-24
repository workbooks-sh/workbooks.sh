defmodule Nexus.WashyFuzzTest do
  @moduledoc """
  DIFFERENTIAL FUZZER (wb-p946): generate random well-typed wasm functions as decoded structs and
  assert the tiered transpiler lane is bit-identical to the pure interpreter. This is the scalable net
  that flushes transpiler op bugs systematically instead of one-corpse-at-a-time from real modules.

  It already caught the s32/s64 variable-capture bug (a fixed temp name reused across two signed ops in
  one expression — `s32(a) =< s32(b)` — exported the first binding so the second became a failing match
  → CaseClauseError). The explicit regression for that is `signed comparisons used twice` below.

  Low fuel so runaway loops trap in BOTH lanes (a shared :out_of_fuel = agreement, not a divergence).
  """
  use ExUnit.Case, async: true

  alias Nexus.Washy

  @fuel 40_000
  @bin [0x6A, 0x6B, 0x6C, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F]
  @un [0x45, 0x67, 0x68, 0x69]

  defp build(instrs) do
    %Washy{
      types: [{[127, 127], [127]}],
      funcs: [0],
      code: [{3, instrs ++ [{:i32_const, 7}]}],
      exports: %{"f" => 0},
      mem: {1, nil},
      globals: [],
      data: [],
      imports: [],
      elements: [],
      # unique id per distinct program so tier_cached never serves a stale build for a different one
      id: :crypto.hash(:sha256, :erlang.term_to_binary(instrs))
    }
  end

  defp outcome(m, args, transpile?) do
    {v, _} = Washy.call_io(m, "f", args, fuel: @fuel, transpile: transpile?, tier_threshold: 1)
    {:value, v}
  rescue
    e in Nexus.Washy.Trap -> {:trap, e.reason}
    e -> {:crash, Exception.message(e)}
  catch
    :throw, {:washy_exit, c} -> {:exit, c}
    k, r -> {:crash, {k, r}}
  end

  defp diverges?(instrs, args) do
    m = build(instrs)
    outcome(m, args, false) != outcome(m, args, true)
  end

  # ── random well-typed generator ──────────────────────────────────────────────────────────────────
  defp gen_body(n, depth), do: Enum.flat_map(1..n, fn _ -> stmt(depth) end)

  defp stmt(depth) do
    case :rand.uniform(10) do
      x when x <= 4 -> [push()]
      5 -> [push(), push(), {:op, Enum.random(@bin)}]
      6 -> [push(), {:op, Enum.random(@un)}]
      7 -> [push(), {:local_set, :rand.uniform(3)}]
      8 -> [{:local_get, :rand.uniform(3) - 1}]
      9 -> if depth < 3, do: loopfrag(depth), else: [push()]
      _ -> if depth < 3, do: blockfrag(depth), else: [push()]
    end
  end

  defp push, do: Enum.random([{:i32_const, :rand.uniform(200) - 100}, {:local_get, :rand.uniform(3) - 1}])

  defp loopfrag(d) do
    inner = Enum.flat_map(1..:rand.uniform(3), fn _ -> stmt(d + 1) end)
    [{:loop, inner ++ [{:local_get, 0}, {:i32_const, 1}, {:op, 0x6B}, {:local_tee, 0}, {:br_if, 0}]}]
  end

  defp blockfrag(d) do
    inner = Enum.flat_map(1..:rand.uniform(3), fn _ -> stmt(d + 1) end)
    [{:block, inner ++ [push(), {:br_if, 0}]}]
  end

  @argsets [[0, 0], [5, 3], [3, 1], [10, 7], [0xFFFFFFFF, 2]]

  test "tiered lane == interpreter across 300 random well-typed programs" do
    bad =
      Enum.find(1..300, fn s ->
        :rand.seed(:exsss, {s, s * 7 + 1, s * 13 + 3})
        instrs = gen_body(7, 0)
        Enum.any?(@argsets, fn args -> diverges?(instrs, args) end)
      end)

    assert bad == nil, "tiered/interp diverged at seed #{inspect(bad)} — run the fuzzer to minimize"
  end

  test "signed comparisons used twice in one expression agree (s32 variable-capture regression)" do
    # le_s(a, b) where BOTH operands need s32; the bug reused one Erlang temp → CaseClauseError.
    for op <- [0x48, 0x4A, 0x4C, 0x4E] do
      instrs = [{:local_get, 0}, {:i32_const, -24}, {:op, op}]
      assert not diverges?(instrs, [5, 3]), "signed op 0x#{Integer.to_string(op, 16)} diverged"
    end
  end

  test "memory.size / memory.grow agree (Phase A op coverage)" do
    # grow(2) returns old page count (1); a store in the grown region + load round-trips; grow-too-big = -1
    cases = [
      {[{:memory_size}], 1},
      {[{:i32_const, 2}, {:memory_grow}], 1},
      {[{:i32_const, 2}, {:memory_grow}, {:drop}, {:i32_const, 70000}, {:i32_const, 12345}, {:i32_store, 0}, {:i32_const, 70000}, {:i32_load, 0}], 12345},
      {[{:i32_const, 999_999}, {:memory_grow}], 0xFFFFFFFF}
    ]

    for {instrs, expected} <- cases do
      m = %{build([]) | code: [{2, instrs}], id: :crypto.hash(:sha256, :erlang.term_to_binary(instrs))}
      {i, _} = Washy.call_io(m, "f", [0, 0], transpile: false)
      {t, _} = Washy.call_io(m, "f", [0, 0], transpile: true, tier_threshold: 1)
      assert i == t and i == expected, "memory op diverged: interp=#{inspect(i)} tiered=#{inspect(t)} exp=#{expected}"
    end
  end

  test "bulk memory (memory.copy / memory.fill) agree (Phase A op coverage)" do
    cases = [
      # fill 8 bytes @100 with 0xAB, read i32 @100
      {[{:i32_const, 100}, {:i32_const, 0xAB}, {:i32_const, 8}, {:memory_fill}, {:i32_const, 100}, {:i32_load, 0}], 2_880_154_539},
      # store, copy 4 bytes 200→300, read @300
      {[{:i32_const, 200}, {:i32_const, 0x12345678}, {:i32_store, 0}, {:i32_const, 300}, {:i32_const, 200}, {:i32_const, 4}, {:memory_copy}, {:i32_const, 300}, {:i32_load, 0}], 0x12345678},
      # overlapping copy (dst>src)
      {[{:i32_const, 0}, {:i32_const, 0x11}, {:i32_const, 16}, {:memory_fill}, {:i32_const, 4}, {:i32_const, 0}, {:i32_const, 8}, {:memory_copy}, {:i32_const, 4}, {:i32_load, 0}], 0x11111111}
    ]

    for {instrs, expected} <- cases do
      m = %{build([]) | code: [{2, instrs}], id: :crypto.hash(:sha256, :erlang.term_to_binary(instrs))}
      {i, _} = Washy.call_io(m, "f", [0, 0], transpile: false)
      {t, _} = Washy.call_io(m, "f", [0, 0], transpile: true, tier_threshold: 1)
      assert i == t and i == expected, "bulk-mem diverged: interp=#{inspect(i)} tiered=#{inspect(t)} exp=#{expected}"
    end
  end

  test "select / clz / ctz / popcnt / unreachable / trunc_sat agree (Phase A op coverage)" do
    cases = [
      {[{:local_get, 0}, {:local_get, 1}, {:i32_const, 1}, {:op, 0x1B}], [10, 20], 10},
      {[{:local_get, 0}, {:local_get, 1}, {:i32_const, 0}, {:op, 0x1B}], [10, 20], 20},
      {[{:i32_const, 1}, {:op, 0x67}], [0, 0], 31},
      {[{:i32_const, 8}, {:op, 0x68}], [0, 0], 3},
      {[{:i32_const, 0xFF}, {:op, 0x69}], [0, 0], 8},
      {[{:i32_const, 0}, {:op, 0x67}], [0, 0], 32},
      {[{:fconst, 3.9}, {:trunc_sat, 2}], [0, 0], 3}
    ]

    for {instrs, args, expected} <- cases do
      m = %{build([]) | code: [{2, instrs}], id: :crypto.hash(:sha256, :erlang.term_to_binary(instrs))}
      {i, _} = Washy.call_io(m, "f", args, transpile: false)
      {t, _} = Washy.call_io(m, "f", args, transpile: true, tier_threshold: 1)
      assert i == t and i == expected, "op diverged: interp=#{inspect(i)} tiered=#{inspect(t)} exp=#{expected}"
    end
  end

  test "calling a VOID function pushes nothing (void-call stack-offset regression)" do
    # g (func 1) is VOID — (i32,i32)->(). The bug: the transpiled caller pushed g's result anyway,
    # shifting the whole comp stack → wrong addresses downstream (the quickjs OOB). Here: call g, then
    # the result we return is local 1, which must be UNAFFECTED by g's (non-)result.
    m = %Washy{
      types: [{[127, 127], [127]}, {[127, 127], []}],
      funcs: [0, 1],
      code: [
        # f: local1 = 42; call g(0,0) [void]; return local1  (must be 42, not g's phantom result)
        {0, [{:i32_const, 42}, {:local_set, 1}, {:i32_const, 0}, {:i32_const, 0}, {:call, 1}, {:local_get, 1}]},
        # g: void — just drops its args implicitly (does nothing observable)
        {0, []}
      ],
      exports: %{"f" => 0},
      mem: {1, nil},
      globals: [],
      data: [],
      imports: [],
      elements: [],
      id: :crypto.hash(:sha256, "voidcall")
    }

    assert {42, _} = Washy.call_io(m, "f", [1, 2], transpile: false)
    assert {42, _} = Washy.call_io(m, "f", [1, 2], transpile: true, tier_threshold: 1)
  end
end

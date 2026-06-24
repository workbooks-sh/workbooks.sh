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
    {v, _} = Washy.call_io(m, "f", args, fuel: @fuel, transpile: transpile?)
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
end

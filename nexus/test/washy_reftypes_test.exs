defmodule Nexus.WashyRefTypesTest do
  @moduledoc """
  WASIX §0 — reference types + mutable table get/set. A funcref is the function index; a null ref is
  `:null`. The table is mutable (held in `:washy_table`), so `table.set` is visible to `call_indirect` —
  proven by setting a table slot at runtime and indirect-calling through it. (table.size/grow/fill, which
  need the declared table size, are the follow-up; wb-81wu.)
  """
  use ExUnit.Case, async: true

  alias Nexus.Washy
  alias Nexus.Washy.TranspileAsm

  # A 1-func module (type [i32,i32]->i32) for the pure ref-op tests.
  defp solo(instrs) do
    %Washy{
      types: [{[127, 127], [127]}],
      funcs: [0],
      code: [{0, instrs}],
      exports: %{"f" => 0},
      mem: {1, nil}, globals: [], data: [], imports: [], elements: [],
      id: :crypto.hash(:sha256, :erlang.term_to_binary(instrs))
    }
  end

  defp run(m), do: Washy.call_io(m, "f", [0, 0], transpile: false) |> elem(0)

  test "ref.null + ref.is_null" do
    assert run(solo([{:ref_null}, {:ref_is_null}])) == 1
    assert run(solo([{:ref_func, 0}, {:ref_is_null}])) == 0
  end

  test "table.get on an unset slot is null (is_null → 1)" do
    assert run(solo([{:i32_const, 7}, {:table_get}, {:ref_is_null}])) == 1
  end

  test "table.set is visible to a later table.get (round-trip a funcref)" do
    # table[5] = ref.func(0); ref.is_null(table.get(5)) → 0
    assert run(solo([
      {:i32_const, 5}, {:ref_func, 0}, {:table_set},
      {:i32_const, 5}, {:table_get}, {:ref_is_null}
    ])) == 0
  end

  # A 2-func module: func 0 sets table[0]=ref.func(1) then indirect-calls it; func 1 returns 99.
  defp indirect_mod do
    %Washy{
      types: [{[], [127]}],
      funcs: [0, 0],
      code: [
        {0, [
          {:i32_const, 0}, {:ref_func, 1}, {:table_set},
          {:i32_const, 0}, {:call_indirect, 0}
        ]},
        {0, [{:i32_const, 99}]}
      ],
      exports: %{"f" => 0},
      mem: {1, nil}, globals: [], data: [], imports: [], elements: [],
      id: :crypto.hash(:sha256, "reftypes-indirect")
    }
  end

  test "a runtime table.set drives call_indirect (dynamic dispatch)" do
    m = indirect_mod()
    {interp, _} = Washy.call_io(m, "f", [], transpile: false)
    assert interp == 99
    # both lanes agree — the transpile lane falls back cleanly on ref/table ops
    {tier, _} = Washy.call_io(m, "f", [], transpile: true, tier_threshold: 1, tier_async: false)
    assert tier == 99
    assert TranspileAsm.try_emit(m, 0) == :unsupported
  end
end

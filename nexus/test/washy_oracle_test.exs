defmodule Nexus.WashyOracleTest do
  @moduledoc """
  The differential oracle classifies each backend's outcome (value / trap / exit) and reports
  agreement. Today there is one backend (`:interp`), so these lock the classifier + the contract;
  when `:transpile` lands the SAME assertions become a true interpreter-vs-transpiler conformance check.
  """
  use ExUnit.Case, async: true

  alias Nexus.Washy
  alias Nexus.Washy.Oracle

  # func0 add(i32,i32)->i32 ; func1 dbl(i32)->i32 = add(x,x)
  @add <<0, 97, 115, 109, 1, 0, 0, 0, 1, 12, 2, 96, 2, 127, 127, 1, 127, 96, 1, 127, 1, 127,
         3, 3, 2, 0, 1, 7, 13, 2, 3, 97, 100, 100, 0, 0, 3, 100, 98, 108, 0, 1,
         10, 18, 2, 7, 0, 32, 0, 32, 1, 106, 11, 8, 0, 32, 0, 32, 0, 16, 0, 11>>

  # ()->i32 "f" = i32.const 10 / i32.const 0 / i32.div_s  (traps :div_by_zero)
  @divz <<0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 0x60, 0, 1, 0x7F, 3, 2, 1, 0, 7, 5, 1, 1, 0x66, 0, 0,
          10, 9, 1, 7, 0, 0x41, 10, 0x41, 0, 0x6D, 0x0B>>

  test "classifies a normal return as {:value, _} and agrees" do
    {:ok, m} = Washy.decode(@add)
    assert Oracle.compare(m, "add", [3, 4]) == {:agree, {:value, 7}}
    assert Oracle.assert_same(m, "dbl", [21]) == {:value, 42}
  end

  test "classifies a trap as {:trap, reason} and agrees" do
    {:ok, m} = Washy.decode(@divz)
    assert Oracle.compare(m, "f", []) == {:agree, {:trap, :div_by_zero}}
    assert Oracle.assert_same(m, "f", []) == {:trap, :div_by_zero}
  end

  test "run/4 on :interp classifies outcomes directly" do
    {:ok, add} = Washy.decode(@add)
    {:ok, divz} = Washy.decode(@divz)
    assert Oracle.run(:interp, add, "add", [100, 23]) == {:value, 123}
    assert Oracle.run(:interp, divz, "f", []) == {:trap, :div_by_zero}
  end

  test "the registry exposes the current backends (transpile joins later)" do
    assert Oracle.backends() == [:interp]
  end
end

defmodule Nexus.WashyTranspileTest do
  @moduledoc """
  wasm→BEAM transpiler, spike v0: a straight-line integer function compiled to a native BEAM function
  must produce the SAME outcome as the interpreter — asserted through the differential oracle over
  `[:interp, :transpile]`. This is the end-to-end pipeline proof: structured tree → Erlang abstract
  forms → :compile.forms → :code.load_binary → BeamAsm, graded against the reference interpreter.
  """
  use ExUnit.Case, async: true

  alias Nexus.Washy
  alias Nexus.Washy.{Oracle, Transpile}

  @both [:interp, :transpile]

  # func0 add(i32,i32)->i32 ; func1 dbl(i32)->i32 = add(x,x)  (dbl uses `call` → outside v0)
  @add <<0, 97, 115, 109, 1, 0, 0, 0, 1, 12, 2, 96, 2, 127, 127, 1, 127, 96, 1, 127, 1, 127,
         3, 3, 2, 0, 1, 7, 13, 2, 3, 97, 100, 100, 0, 0, 3, 100, 98, 108, 0, 1,
         10, 18, 2, 7, 0, 32, 0, 32, 1, 106, 11, 8, 0, 32, 0, 32, 0, 16, 0, 11>>

  # poly(a,b) = ((a + b) * a) - b  — exercises nested stack-as-AST (add, mul, sub)
  @poly <<0, 97, 115, 109, 1, 0, 0, 0, 1, 7, 1, 0x60, 2, 0x7F, 0x7F, 1, 0x7F, 3, 2, 1, 0,
          7, 8, 1, 4, 0x70, 0x6F, 0x6C, 0x79, 0, 0,
          10, 15, 1, 13, 0, 0x20, 0, 0x20, 1, 0x6A, 0x20, 0, 0x6C, 0x20, 1, 0x6B, 0x0B>>

  test "transpiled `add` agrees with the interpreter (incl. 32-bit wraparound)" do
    {:ok, m} = Washy.decode(@add)
    assert Oracle.compare(m, "add", [3, 4], @both) == {:agree, {:value, 7}}
    assert Oracle.compare(m, "add", [100, 23], @both) == {:agree, {:value, 123}}
    # i32 wraps: 0xFFFFFFFF + 1 == 0 in BOTH backends
    assert Oracle.compare(m, "add", [0xFFFFFFFF, 1], @both) == {:agree, {:value, 0}}
  end

  test "transpiled `poly` (nested add/mul/sub) agrees with the interpreter" do
    {:ok, m} = Washy.decode(@poly)

    for {a, b} <- [{2, 3}, {10, 5}, {0, 0}, {7, 1}, {0xFFFFFFFF, 2}] do
      # ((a+b)*a - b), all masked to 32 bits — assert_same raises if the backends ever diverge
      assert {:value, _} = Oracle.assert_same(m, "poly", [a, b], @both)
    end
  end

  test "the transpiled function is genuinely native BEAM code (loaded module)" do
    {:ok, m} = Washy.decode(@add)
    assert {:ok, f} = Transpile.compile(m, "add")
    assert is_function(f, 1)
    assert f.([21, 21]) == 42
  end

  test "outside-v0 functions are scoped out cleanly, not miscompiled" do
    {:ok, m} = Washy.decode(@add)
    # `dbl` uses `call` — not yet supported; must report unsupported, never wrong code
    assert {:error, {:unsupported, _}} = Transpile.compile(m, "dbl")
    # and the interpreter still runs it fine
    assert Washy.call(m, "dbl", [21]) == 42
  end
end

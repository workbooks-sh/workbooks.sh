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

  # ── locals + control flow + calls — grown past v0 ──────────────────────────────────────────────

  # sumto(n) = n + (n-1) + ... + 1, via block/loop/br_if/br + i32.eqz/add/sub + a mutable local (1).
  @sumto <<
    0, 97, 115, 109, 1, 0, 0, 0,
    1, 6, 1, 96, 1, 127, 1, 127,
    3, 2, 1, 0,
    7, 9, 1, 5, 115, 117, 109, 116, 111, 0, 0,
    10, 35, 1, 33, 1, 1, 127,
    2, 64, 3, 64, 32, 0, 69, 13, 1, 32, 1, 32, 0, 106, 33, 1, 32, 0, 65, 1, 107, 33, 0, 12, 0, 11, 11, 32, 1, 11
  >>

  # pick(c) = 100 if c else 200 (if/else that yields a value)
  @pick <<
    0, 97, 115, 109, 1, 0, 0, 0,
    1, 6, 1, 96, 1, 127, 1, 127,
    3, 2, 1, 0,
    7, 8, 1, 4, 112, 105, 99, 107, 0, 0,
    10, 16, 1, 14, 0, 32, 0, 4, 127, 65, 228, 0, 5, 65, 200, 1, 11, 11
  >>

  test "transpiled `dbl` (a direct call to `add`) agrees with the interpreter" do
    {:ok, m} = Washy.decode(@add)
    assert {:ok, f} = Transpile.compile(m, "dbl")
    assert f.([21]) == 42

    for x <- [0, 1, 7, 1000, 0x7FFFFFFF] do
      assert Oracle.assert_same(m, "dbl", [x], @both) == {:value, Washy.call(m, "dbl", [x])}
    end
  end

  test "transpiled `pick` (if/else) agrees with the interpreter" do
    {:ok, m} = Washy.decode(@pick)
    assert Oracle.compare(m, "pick", [1], @both) == {:agree, {:value, 100}}
    assert Oracle.compare(m, "pick", [0], @both) == {:agree, {:value, 200}}
    assert Oracle.compare(m, "pick", [42], @both) == {:agree, {:value, 100}}
  end

  test "transpiled `sumto` (block/loop/br_if/br + mutable local) agrees with the interpreter" do
    {:ok, m} = Washy.decode(@sumto)

    for n <- [0, 1, 5, 10, 100, 1000] do
      assert Oracle.assert_same(m, "sumto", [n], @both) == {:value, div(n * (n + 1), 2)}
    end
  end

  test "transpiled `sumto` is genuinely native and yields the canonical loop results" do
    {:ok, m} = Washy.decode(@sumto)
    assert {:ok, f} = Transpile.compile(m, "sumto")
    assert f.([5]) == 15
    assert f.([100]) == 5050
  end
end

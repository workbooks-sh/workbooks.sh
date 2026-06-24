defmodule Nexus.WashyTranspileTest do
  @moduledoc """
  wasm→BEAM transpiler, spike v0: a straight-line integer function compiled to a native BEAM function
  must produce the SAME outcome as the interpreter — asserted through the differential oracle over
  `[:interp, :transpile]`. This is the end-to-end pipeline proof: structured tree → Erlang abstract
  forms → :compile.forms → :code.load_binary → BeamAsm, graded against the reference interpreter.
  """
  use ExUnit.Case, async: true
  import Bitwise

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

  # ── i64 ops ─────────────────────────────────────────────────────────────────────────────────────

  # f(a,b):i64 = (a*b) - a, masked to 64 bits
  @i64poly <<0, 97, 115, 109, 1, 0, 0, 0, 1, 7, 1, 96, 2, 126, 126, 1, 126, 3, 2, 1, 0, 7, 5, 1, 1,
             102, 0, 0, 10, 12, 1, 10, 0, 32, 0, 32, 1, 126, 32, 0, 125, 11>>

  # f(x:i64):i32 = i32.wrap_i64(i64.rotl(x, 4))
  @i64rot <<0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 126, 1, 127, 3, 2, 1, 0, 7, 5, 1, 1, 102,
            0, 0, 10, 10, 1, 8, 0, 32, 0, 66, 4, 137, 167, 11>>

  # f(x:i32):i64 = i64.extend_i32_s(x)
  @i64ext <<0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 127, 1, 126, 3, 2, 1, 0, 7, 5, 1, 1, 102,
            0, 0, 10, 7, 1, 5, 0, 32, 0, 172, 11>>

  test "transpiled i64 arith `(a*b)-a` agrees with the interpreter (incl. 64-bit wrap)" do
    {:ok, m} = Washy.decode(@i64poly)

    for {a, b} <- [{7, 9}, {0, 0}, {0xFFFFFFFFFFFFFFFF, 2}, {123_456_789, 987_654_321}] do
      assert {:value, _} = Oracle.assert_same(m, "f", [a, b], @both)
    end

    assert Oracle.compare(m, "f", [7, 9], @both) == {:agree, {:value, 56}}
  end

  test "transpiled i64 rotl + i32.wrap_i64 agrees with the interpreter" do
    {:ok, m} = Washy.decode(@i64rot)

    for x <- [0, 1, 0x1234567890ABCDEF, 0xFFFFFFFFFFFFFFFF] do
      assert {:value, _} = Oracle.assert_same(m, "f", [x], @both)
    end
  end

  test "transpiled i64.extend_i32_s agrees with the interpreter (sign extension)" do
    {:ok, m} = Washy.decode(@i64ext)
    assert Oracle.compare(m, "f", [0xFFFFFFFF], @both) == {:agree, {:value, 0xFFFFFFFFFFFFFFFF}}
    assert Oracle.compare(m, "f", [1], @both) == {:agree, {:value, 1}}
    assert Oracle.compare(m, "f", [0x80000000], @both) == {:agree, {:value, 0xFFFFFFFF80000000}}
  end

  # ── memory load/store ───────────────────────────────────────────────────────────────────────────

  # f(addr,v):i32 = { i32.store[addr]=v ; i32.load[addr] }   (1 page memory)
  @mem32 <<0, 97, 115, 109, 1, 0, 0, 0, 1, 7, 1, 96, 2, 127, 127, 1, 127, 3, 2, 1, 0, 5, 3, 1, 0, 1,
           7, 5, 1, 1, 102, 0, 0, 10, 16, 1, 14, 0, 32, 0, 32, 1, 54, 2, 0, 32, 0, 40, 2, 0, 11>>

  # f(addr,v):i32 = { i32.store8[addr]=v ; i32.load8_s[addr] }
  @mem8 <<0, 97, 115, 109, 1, 0, 0, 0, 1, 7, 1, 96, 2, 127, 127, 1, 127, 3, 2, 1, 0, 5, 3, 1, 0, 1,
          7, 5, 1, 1, 102, 0, 0, 10, 16, 1, 14, 0, 32, 0, 32, 1, 58, 0, 0, 32, 0, 44, 0, 0, 11>>

  # f(addr,v:i64):i64 = { i64.store[addr]=v ; i64.load[addr] }
  @mem64 <<0, 97, 115, 109, 1, 0, 0, 0, 1, 7, 1, 96, 2, 127, 126, 1, 126, 3, 2, 1, 0, 5, 3, 1, 0, 1,
           7, 5, 1, 1, 102, 0, 0, 10, 16, 1, 14, 0, 32, 0, 32, 1, 55, 3, 0, 32, 0, 41, 3, 0, 11>>

  # f():i32 = i32.load[0]  with a data segment "ABCD" at offset 0
  @dataseg <<0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 127, 3, 2, 1, 0, 5, 3, 1, 0, 1, 7, 5,
             1, 1, 102, 0, 0, 11, 10, 1, 0, 65, 0, 11, 4, 65, 66, 67, 68, 10, 9, 1, 7, 0, 65, 0, 40,
             2, 0, 11>>

  test "transpiled i32 store/load roundtrip agrees with the interpreter" do
    {:ok, m} = Washy.decode(@mem32)

    for {addr, v} <- [{0, 0xDEADBEEF}, {16, 42}, {64, 0xFFFFFFFF}, {100, 0}] do
      assert {:value, _} = Oracle.assert_same(m, "f", [addr, v], @both)
    end

    assert Oracle.compare(m, "f", [16, 0xDEADBEEF], @both) == {:agree, {:value, 0xDEADBEEF}}
  end

  test "transpiled store8/load8_s sign-extends like the interpreter" do
    {:ok, m} = Washy.decode(@mem8)
    # 200 stored as a byte → load8_s sign-extends to 0xFFFFFFC8
    assert Oracle.compare(m, "f", [3, 200], @both) == {:agree, {:value, 0xFFFFFFC8}}
    assert Oracle.compare(m, "f", [3, 5], @both) == {:agree, {:value, 5}}
  end

  test "transpiled i64 store/load roundtrip agrees with the interpreter" do
    {:ok, m} = Washy.decode(@mem64)
    assert Oracle.compare(m, "f", [8, 0x1122334455667788], @both) ==
             {:agree, {:value, 0x1122334455667788}}
  end

  test "transpiled load past memory bounds traps :out_of_bounds, like the interpreter" do
    {:ok, m} = Washy.decode(@mem32)
    # 100000 is past the single 64KB page → both backends must trap identically
    assert Oracle.compare(m, "f", [100_000, 5], @both) == {:agree, {:trap, :out_of_bounds}}
  end

  test "transpiled data-segment init + load agrees with the interpreter" do
    {:ok, m} = Washy.decode(@dataseg)
    # "ABCD" little-endian = 0x44434241
    assert Oracle.compare(m, "f", [], @both) == {:agree, {:value, 0x44434241}}
  end

  # ── floats ──────────────────────────────────────────────────────────────────────────────────────

  # f(a,b:f64):f64 = sqrt(a*a + b*b)
  @hypot <<0, 97, 115, 109, 1, 0, 0, 0, 1, 7, 1, 96, 2, 124, 124, 1, 124, 3, 2, 1, 0, 7, 5, 1, 1,
           102, 0, 0, 10, 16, 1, 14, 0, 32, 0, 32, 0, 162, 32, 1, 32, 1, 162, 160, 159, 11>>

  # f(x:i32):f32 = f32.convert_i32_s(x) * 1.5
  @f32mul <<0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 127, 1, 125, 3, 2, 1, 0, 7, 5, 1, 1, 102,
            0, 0, 10, 13, 1, 11, 0, 32, 0, 178, 67, 0, 0, 192, 63, 148, 11>>

  # f(addr,x:f32):i32 = { f32.store[addr]=x ; i32.reinterpret_f32(f32.load[addr]) }
  @f32mem <<0, 97, 115, 109, 1, 0, 0, 0, 1, 7, 1, 96, 2, 127, 125, 1, 127, 3, 2, 1, 0, 5, 3, 1, 0,
            1, 7, 5, 1, 1, 102, 0, 0, 10, 17, 1, 15, 0, 32, 0, 32, 1, 56, 2, 0, 32, 0, 42, 2, 0,
            188, 11>>

  test "transpiled f64 hypot (mul/add/sqrt) agrees with the interpreter" do
    {:ok, m} = Washy.decode(@hypot)
    assert Oracle.compare(m, "f", [3.0, 4.0], @both) == {:agree, {:value, 5.0}}

    for {a, b} <- [{1.0, 0.0}, {5.0, 12.0}, {0.5, 0.5}] do
      assert {:value, _} = Oracle.assert_same(m, "f", [a, b], @both)
    end
  end

  test "transpiled f32 convert + mul (single-precision rounded) agrees with the interpreter" do
    {:ok, m} = Washy.decode(@f32mul)

    for x <- [0, 10, -3, 7, 1000] do
      assert {:value, _} = Oracle.assert_same(m, "f", [x &&& 0xFFFFFFFF], @both)
    end
  end

  test "transpiled f32 store/load + reinterpret agrees with the interpreter (bit-exact)" do
    {:ok, m} = Washy.decode(@f32mem)
    # 1.5 as f32 little-endian bits = 0x3FC00000
    assert Oracle.compare(m, "f", [0, 1.5], @both) == {:agree, {:value, 0x3FC00000}}
  end

  # ── br_table ────────────────────────────────────────────────────────────────────────────────────

  # f(i):i32 = switch(i){0 -> 10; 1 -> 20; default -> 30} via nested blocks + br_table
  @brtable <<0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 127, 1, 127, 3, 2, 1, 0, 7, 5, 1, 1, 102,
             0, 0, 10, 29, 1, 27, 0, 2, 64, 2, 64, 2, 64, 32, 0, 14, 2, 0, 1, 2, 11, 65, 10, 15, 11,
             65, 20, 15, 11, 65, 30, 15, 11>>

  test "transpiled br_table switch agrees with the interpreter" do
    {:ok, m} = Washy.decode(@brtable)
    assert Oracle.compare(m, "f", [0], @both) == {:agree, {:value, 10}}
    assert Oracle.compare(m, "f", [1], @both) == {:agree, {:value, 20}}
    assert Oracle.compare(m, "f", [2], @both) == {:agree, {:value, 30}}
    assert Oracle.compare(m, "f", [99], @both) == {:agree, {:value, 30}}
  end

  # ── call_indirect ───────────────────────────────────────────────────────────────────────────────

  # f0 add1(x)=x+1, f1 dbl(x)=x*2 (both (i32)->i32); table[0..1]=[f0,f1].
  # dispatch(sel,x):i32 = call_indirect[ (i32)->i32 ]( table[sel], x )
  @callind <<0, 97, 115, 109, 1, 0, 0, 0, 1, 12, 2, 96, 1, 127, 1, 127, 96, 2, 127, 127, 1, 127, 3,
             4, 3, 0, 0, 1, 4, 4, 1, 112, 0, 2, 7, 12, 1, 8, 100, 105, 115, 112, 97, 116, 99, 104, 0,
             2, 9, 8, 1, 0, 65, 0, 11, 2, 0, 1, 10, 27, 3, 7, 0, 32, 0, 65, 1, 106, 11, 7, 0, 32, 0,
             65, 2, 108, 11, 9, 0, 32, 1, 32, 0, 17, 0, 0, 11>>

  test "transpiled call_indirect dispatches through the table, agreeing with the interpreter" do
    {:ok, m} = Washy.decode(@callind)
    # sel 0 → add1(10) = 11 ; sel 1 → dbl(10) = 20
    assert Oracle.compare(m, "dispatch", [0, 10], @both) == {:agree, {:value, 11}}
    assert Oracle.compare(m, "dispatch", [1, 10], @both) == {:agree, {:value, 20}}
    assert Oracle.compare(m, "dispatch", [0, 7], @both) == {:agree, {:value, 8}}
    # an out-of-range index → both backends trap :undefined_element
    assert Oracle.compare(m, "dispatch", [5, 10], @both) == {:agree, {:trap, :undefined_element}}
  end
end

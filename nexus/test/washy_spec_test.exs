defmodule Nexus.WashySpecTest do
  @moduledoc """
  Phase C (wb-6tgv): the spec-test harness end-to-end — parse `.wast` → assemble WAT → run Washy →
  check `assert_return` / `assert_trap` / `assert_invalid`. Proves the full pipeline on an inline
  script; pointing it at the upstream suite is then just `SpecTest.run_file/1`.
  """
  use ExUnit.Case, async: true

  alias Nexus.Washy.{Sexp, Wat, SpecTest}

  test "WAT assembler round-trips flat, folded, $named, control-flow, and memory funcs" do
    asm = fn wat, f, args ->
      [m] = Sexp.parse_all(wat)
      {:ok, bytes} = Wat.assemble(m)
      {:ok, mod} = Nexus.Washy.decode(bytes)
      Nexus.Washy.call(mod, f, args)
    end

    assert asm.(~s|(module (func (export "add") (param $x i32) (param $y i32) (result i32) local.get $x local.get $y i32.add))|, "add", [3, 4]) == 7
    assert asm.(~s|(module (func (export "fold") (param $x i32) (result i32) (i32.mul (local.get $x) (i32.const 3))))|, "fold", [7]) == 21
    assert asm.(~s|(module (memory 1) (func (export "m") (result i32) i32.const 8 i32.const 42 i32.store i32.const 8 i32.load))|, "m", []) == 42
  end

  test "a .wast script with assert_return / assert_trap / assert_invalid all pass" do
    wast = ~S"""
    (module
      (memory 1)
      (func (export "add") (param $x i32) (param $y i32) (result i32)
        local.get $x local.get $y i32.add)
      (func (export "divz") (param $x i32) (result i32)
        local.get $x i32.const 0 i32.div_s)
      (func (export "oob") (result i32)
        i32.const 100000 i32.load))

    (assert_return (invoke "add" (i32.const 3) (i32.const 4)) (i32.const 7))
    (assert_return (invoke "add" (i32.const 4294967295) (i32.const 1)) (i32.const 0))
    (assert_trap (invoke "divz" (i32.const 10)) "integer divide by zero")
    (assert_trap (invoke "oob") "out of bounds memory access")

    ;; a module that calls a non-existent function — validation must reject it
    (assert_invalid
      (module (func (export "bad") call 99))
      "unknown function")
    """

    r = SpecTest.run(wast)
    assert r.failures == []
    assert r.fail == 0
    assert r.pass == 5
    assert SpecTest.pass_rate(r) == 1.0
  end

  test "an assert_return mismatch is recorded as a failure (the harness can detect wrong answers)" do
    wast = ~S"""
    (module (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))
    (assert_return (invoke "add" (i32.const 2) (i32.const 2)) (i32.const 5))
    """

    r = SpecTest.run(wast)
    assert r.fail == 1
    assert r.pass == 0
  end

  test "unsupported directives are skipped, not failed" do
    wast = ~S"""
    (module (func (export "f") (result i32) i32.const 1))
    (assert_return (invoke "f") (i32.const 1))
    (assert_exhaustion (invoke "f") "call stack exhausted")
    (register "m")
    """

    r = SpecTest.run(wast)
    assert r.pass == 1
    assert r.skip == 2
    assert r.fail == 0
  end
end

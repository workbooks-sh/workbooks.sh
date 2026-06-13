defmodule Workbooks.Reclaim.CommonLispTest do
  @moduledoc """
  RECLAIM: Common Lisp — a genuine ANSI-CL-SUBSET interpreter, compiled via clang.wasm and
  evaluating real Lisp programs entirely in-sandbox.

  HONEST SCOPE: this is NOT SBCL (SBCL requires native machine-code generation, impossible in the
  wasm sandbox). It is a working Common-Lisp-subset *interpreter* written in C
  (test/reclaim/fixtures/common_lisp/lisp.c): cons cells, interned symbols, lexically-scoped
  closures, an s-expr reader (incl. quote), eval with special forms
  quote/if/cond/lambda/defun/define/setq/let/progn, and primitives + - * = < > cons car cdr atom
  null list eq not. It evaluates recursion, list building, and higher-order lambdas.

  The interpreter source is compiled THROUGH the wasm C lane (BuildBroker.build_and_run(:c, ...))
  and the Lisp program is fed on stdin; the interpreter reads, evaluates, and prints the value of
  the last top-level form. Each case asserts on the printed value, so it proves the Lisp runtime
  actually computes — not just that the C compiled.

  @tag :build — exercises the full clang.wasm compile lane (slow).
  """
  use ExUnit.Case, async: false
  alias Workbooks.BuildBroker

  @lisp_c File.read!(Path.join(__DIR__, "fixtures/common_lisp/lisp.c"))

  defp lisp(program, expected) do
    case BuildBroker.build_and_run(:c, @lisp_c, program, allow: true, max_source: 2_000_000) do
      {:ok, out} ->
        assert String.trim(out) == expected,
               "lisp program produced #{inspect(String.trim(out))}, expected #{inspect(expected)}\nprogram:\n#{program}"

      {:error, reason} ->
        flunk("C compile/run lane failed: #{inspect(reason)}")
    end
  end

  @tag :build
  @tag timeout: 600_000
  test "recursive factorial via defun + if + recursion" do
    lisp(
      """
      (defun fact (n) (if (< n 2) 1 (* n (fact (- n 1)))))
      (fact 6)
      """,
      "720"
    )
  end

  @tag :build
  @tag timeout: 600_000
  test "recursive list length via cons/car/cdr/null + cond" do
    lisp(
      """
      (defun len (xs) (cond ((null xs) 0) (t (+ 1 (len (cdr xs))))))
      (len (quote (a b c d e)))
      """,
      "5"
    )
  end

  @tag :build
  @tag timeout: 600_000
  test "lexical closure: lambda captures let-bound env and builds a list" do
    lisp(
      """
      (defun mapcar1 (f xs)
        (cond ((null xs) nil)
              (t (cons (f (car xs)) (mapcar1 f (cdr xs))))))
      (let ((k 10))
        (mapcar1 (lambda (x) (+ x k)) (quote (1 2 3))))
      """,
      "(11 12 13)"
    )
  end

  @tag :build
  @tag timeout: 600_000
  test "arithmetic + equality predicates" do
    lisp(
      """
      (defun fib (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
      (list (fib 10) (= 55 (fib 10)) (< 1 2) (not nil))
      """,
      "(55 t t t)"
    )
  end
end

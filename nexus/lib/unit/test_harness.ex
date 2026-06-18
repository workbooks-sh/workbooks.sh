defmodule Nexus.Unit.TestHarness do
  @moduledoc """
  A tiny test vocabulary for `test` units — the `run_tests` weave gate, executed on the
  BEAM. A `test :score` unit's `test "…" do assert … end` blocks become callable
  functions; `assert` raises a descriptive error on a falsy expression. Deliberately
  not ExUnit, so a workbook's tests run in-process without nesting an ExUnit run.
  """

  defmacro __using__(_opts), do: quote(do: import(Nexus.Unit.TestHarness))

  @doc "A test case → a zero-arity function returning :ok (or raising via assert)."
  defmacro test(_desc, do: body) do
    fname = :"wbtest_#{System.unique_integer([:positive])}"

    quote do
      def unquote(fname)() do
        unquote(body)
        :ok
      end
    end
  end

  @doc "Raise a descriptive error unless the expression is truthy."
  defmacro assert(expr) do
    rendered = Macro.to_string(expr)

    quote do
      unless unquote(expr), do: raise("assertion failed: " <> unquote(rendered))
    end
  end

  @doc "The generated test functions of a compiled test module."
  def cases(module) do
    for {fun, 0} <- module.__info__(:functions),
        String.starts_with?(Atom.to_string(fun), "wbtest_"),
        do: fun
  end
end

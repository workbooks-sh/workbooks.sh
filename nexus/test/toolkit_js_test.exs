defmodule Nexus.Toolkit.JsTest do
  use ExUnit.Case, async: true
  alias Nexus.Toolkit.Js

  @src """
  def sum([]), do: 0
  def sum([h | t]), do: h + sum(t)

  def classify({:ok, v}), do: "ok:" <> to_string(v)
  def classify({:error, _}), do: "err"

  def count_down(0, acc), do: acc
  def count_down(n, acc), do: count_down(n - 1, acc + n)

  def shout(msg) do
    emit(msg)
    String.upcase(msg)
  end
  """

  test "transpiles a functional Elixir subset to JS" do
    {:ok, js} = Js.transpile(@src)

    # list patterns → cons-cell ABI
    assert js =~ "a0 instanceof $Empty"
    assert js =~ "a0 instanceof $NonEmpty"
    assert js =~ "a0.head"
    assert js =~ "a0.tail"

    # tuple/atom patterns
    assert js =~ ~s(a0[0] === "ok")
    assert js =~ ~s(a0[0] === "error")

    # integer-literal pattern guards the clause (the bug the spike caught)
    assert js =~ "a0 === 0"

    # self-tail-recursion → while-loop TCO (count_down), but NOT for body-recursive sum
    assert js =~ "function count_down(a0, a1) {\n  while (true) {"
    refute js =~ "function sum(a0) {\n  while (true)"
    assert js =~ "continue;"

    # capability call + String shim
    assert js =~ "$host.emit(msg)"
    assert js =~ "(msg).toUpperCase()"
  end

  test "runnable/1 prepends the prelude" do
    {:ok, js} = Js.runnable(@src)
    assert js =~ "class $NonEmpty"
    assert js =~ "function $toList"
    assert js =~ "function classify(a0)"
  end

  test "rejects source with no defs" do
    assert {:error, :no_defs} = Js.transpile("x = 1")
  end

  test "exports/1 lists toolkit functions" do
    {:ok, exs} = Js.exports(@src)
    assert {:sum, 1} in exs
    assert {:classify, 1} in exs
    assert {:count_down, 2} in exs
    assert {:shout, 1} in exs
  end

  test "Toolkit.build routes an Elixir toolkit through the JS lane and registers it" do
    Js.clear()
    node = %{kind: "toolkit", name: "demo", header: "", body: @src}
    assert {:ok, "demo"} = Nexus.Toolkit.build(node)
    assert %{name: "demo", js: js, exports: exs} = Js.lookup("demo")
    assert js =~ "function sum(a0)"
    assert {:sum, 1} in exs
  end

  test "lang inference picks :elixir for def-bodies, keeps c/rust/zig otherwise" do
    assert Nexus.Toolkit.lang(%{header: "", body: "def f(x), do: x"}) == "elixir"
    assert Nexus.Toolkit.lang(%{header: "", body: "int main(void){return 0;}"}) == "c"
    assert Nexus.Toolkit.lang(%{header: "", body: "fn main() {}"}) == "rust"
    assert Nexus.Toolkit.lang(%{header: "lang: elixir", body: "x"}) == "elixir"
  end

  # Behavioral check: build the same driver Js.invoke/4 uses, and run it — via the StarlingMonkey
  # eval-host if present, else node (engine wasm is gitignored, so node is the portable check).
  @tag :js_exec
  test "driver output runs and produces correct results" do
    {:ok, js} = Js.runnable(@src)
    cases = [
      {Js.driver(js, "sum", [[1, 2, 3, 4, 5]]), 15},
      {Js.driver(js, "count_down", [100_000, 0]), 5_000_050_000},
      {Js.driver(js, "shout", ["hello"]), "HELLO"}
    ]

    node = System.find_executable("node")
    if node do
      for {src, expected} <- cases do
        path = Path.join(System.tmp_dir!(), "tk_#{System.unique_integer([:positive])}.mjs")
        # driver assigns $result then bare-references it; for node we print it
        File.write!(path, src <> "\nconsole.log($result);\n")
        try do
          {out, 0} = System.cmd(node, [path])
          assert Jason.decode!(String.trim(out)) == expected
        after
          File.rm(path)
        end
      end
    end
  end
end

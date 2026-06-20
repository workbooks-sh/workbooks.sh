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

  # Behavioral check: actually run the transpiled JS and verify outputs match Elixir semantics.
  # Uses a tiny embedded JS evaluator? No — we shell to node if available (engine wasm is gitignored).
  @tag :js_exec
  test "transpiled JS produces correct results when executed" do
    {:ok, body} = Js.runnable(@src)

    driver = """
    var $host = { emit: function(m){ return m; } };
    var out = [];
    out.push(sum($toList([1,2,3,4,5])));
    out.push(classify(["ok", 42]));
    out.push(classify(["error", "x"]));
    out.push(count_down(100000, 0));
    out.push(shout("hello"));
    console.log(JSON.stringify(out));
    """

    case System.find_executable("node") do
      nil ->
        # no node in this env — skip the exec check (transpile structure is covered above)
        :ok

      node ->
        path = Path.join(System.tmp_dir!(), "tk_#{System.unique_integer([:positive])}.mjs")
        File.write!(path, body <> "\n" <> driver)

        try do
          {out, 0} = System.cmd(node, [path])
          assert Jason.decode!(String.trim(out)) == [15, "ok:42", "err", 5_000_050_000, "HELLO"]
        after
          File.rm(path)
        end
    end
  end
end

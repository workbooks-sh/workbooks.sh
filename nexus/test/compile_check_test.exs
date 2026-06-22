defmodule Nexus.CompileCheckTest do
  # async: false — check/1 compiles modules (run isolated in prod via `nexus eval`; here it's fine).
  use ExUnit.Case, async: false

  defp mk(body) do
    d = Path.join(System.tmp_dir!(), "chk_#{System.unique_integer([:positive])}")
    File.mkdir_p!(d)
    File.write!(Path.join(d, "index.work"), body)
    d
  end

  test "clean server compiles → ok?" do
    r = Nexus.Compile.check(mk("server :ok1 do\n  def h(_), do: %{ok: true}\nend\n"))
    assert r.ok?
    assert r.errors == []
  end

  test "undefined function → error (not silently passed)" do
    r = Nexus.Compile.check(mk("server :bad1 do\n  def h(_), do: undefined_xyz_fn()\nend\n"))
    refute r.ok?
    assert Enum.any?(r.errors, &(&1.kind == "server"))
  end

  test "SYNTAX error in a server body → error (the lenient-parser hole)" do
    r = Nexus.Compile.check(mk("server :syn1 do\n  def f(  , do: 1\nend\n"))
    refute r.ok?
    assert Enum.any?(r.errors, &(&1.reason =~ "syntax error"))
  end

  test "client block is render-passthrough → ok? + reported as skipped, never silently 'checked'" do
    r = Nexus.Compile.check(mk("client :isl do\n  <button>hi</button>\nend\n"))
    assert r.ok?
    assert Enum.any?(r.skipped, &(&1.kind == "client"))
  end

  test "wasm lane reported as skipped (no in-image toolchain), not failed" do
    r = Nexus.Compile.check(mk("rust :fast do\n  pub fn add(a: i32, b: i32) -> i32 { a + b }\nend\n"))
    assert r.ok?
    assert Enum.any?(r.skipped, &(&1.kind == "rust"))
  end

  test "a malformed Elixir-lane unit other than server is caught too" do
    # a hook whose body fails to parse → syntax error captured (not a silent warning)
    r = Nexus.Compile.check(mk("hook :h1 do\n  match \"x\" do  ( unbalanced\nend\n"))
    refute r.ok?
  end

  test "mixed tree: one good surface + one broken unit → fails, names the culprit" do
    body = """
    server :good do
      def a(_), do: 1
    end

    server :broken do
      def b(_), do: nope_undefined()
    end
    """

    r = Nexus.Compile.check(mk(body))
    refute r.ok?
    assert Enum.any?(r.errors, &(&1.name == "broken"))
    refute Enum.any?(r.errors, &(&1.name == "good"))
  end
end

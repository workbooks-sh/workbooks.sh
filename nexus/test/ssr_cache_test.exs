defmodule Nexus.SSRCacheTest do
  # P1 (perf): the render/`/data` path memoises the two tenant-INVARIANT layers — parsing a surface's
  # `.work` files (`Nexus.SSR` parse cache, keyed by a content signature) and compiling `resource`
  # structs (`Nexus.Resource.compile`). These tests lock in that the caches are TRANSPARENT (never
  # change output) and SELF-INVALIDATING (a content change is reflected).
  use ExUnit.Case, async: false

  defp wb(name, body) do
    dir = Path.join(System.tmp_dir!(), "p1_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), body)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "parse cache is transparent (repeat render byte-identical) and populated per root" do
    dir = wb("index.work", "# Alpha\n\nresource FooP1 do\n  id :id\n  name :text\nend\n")

    h1 = Nexus.SSR.render(dir)
    h2 = Nexus.SSR.render(dir)

    assert h1 == h2, "a cached render must be byte-identical to the first"
    assert h1 =~ "Alpha"
    # cache lives in persistent_term, keyed by root, holding {signature, parsed_pages}
    assert match?({_sig, _pages}, :persistent_term.get({Nexus.SSR, :parse_cache, dir}, nil))
  end

  test "parse cache busts when a .work file changes (no stale content served)" do
    dir = wb("index.work", "# Alpha\n\nresource FooP1b do\n  id :id\n  name :text\nend\n")

    h1 = Nexus.SSR.render(dir)
    assert h1 =~ "Alpha"

    # rewrite with different content AND size → signature changes → re-parse
    File.write!(Path.join(dir, "index.work"), "# Beta\n\nresource FooP1b do\n  id :id\n  name :text\n  extra :int\nend\n")
    h2 = Nexus.SSR.render(dir)

    assert h2 =~ "Beta"
    refute h2 =~ "Alpha"
  end

  test "SSR.data is transparent under the cache and returns the surface's resources" do
    dir = wb("index.work", "resource ItemP1 do\n  id :id\n  qty :int\nend\n")

    d1 = Nexus.SSR.data(dir)
    d2 = Nexus.SSR.data(dir)

    assert d1 == d2
    assert Map.has_key?(d1, "ItemP1")
  end

  test "Nexus.Resource.compile memoises: same fields reuse the module, changed fields recompile" do
    node = fn body ->
      ("resource BarP1 do\n" <> body <> "end\n")
      |> Nexus.Literate.parse()
      |> Enum.find(&(&1.type == :code))
    end

    m1 = Nexus.Resource.compile(node.("  id :id\n  name :text\n"))
    m2 = Nexus.Resource.compile(node.("  id :id\n  name :text\n"))

    assert m1 == m2, "unchanged fields must reuse the loaded module (no recompile)"
    assert Enum.map(m1.__fields__(), &elem(&1, 0)) == [:id, :name]

    # a fields change on the same resource name self-invalidates: same module atom, updated __fields__
    m3 = Nexus.Resource.compile(node.("  id :id\n  name :text\n  extra :int\n"))
    assert m3 == m1
    assert Enum.map(m3.__fields__(), &elem(&1, 0)) == [:id, :name, :extra]
  end
end

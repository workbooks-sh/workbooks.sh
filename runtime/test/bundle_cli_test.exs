defmodule Workbooks.BundleCliTest do
  @moduledoc """
  Pins the `work bundle <dir> <out.html>` / `work unbundle <in.html> <dir>` verbs over
  the existing Bundle primitives: a dir tree round-trips dir → .html → dir
  byte-exact, the page survives, and the unbundle path-guard rejects escapes.
  Hermetic — no network, no LLM, no GenServer (the tree carries its own index.html
  so `OQL.render` is never invoked).
  """
  use ExUnit.Case, async: true
  alias Workbooks.CLI

  setup do
    base = Path.join(System.tmp_dir!(), "wb_bundle_cli_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  test "work bundle → work unbundle round-trips a dir tree byte-exact", %{base: base} do
    src = Path.join(base, "src")
    out = Path.join(base, "page.html")
    dst = Path.join(base, "dst")

    tree = %{
      "index.html" => "<!doctype html><html><body><h1>app</h1></body></html>",
      "data/blob.bin" => :crypto.strong_rand_bytes(4096),
      "src/app.svelte" => "<h1>{count}</h1>\n",
      "workspace.org" => "* Hello\nintro\n"
    }

    for {name, content} <- tree do
      p = Path.join(src, name)
      File.mkdir_p!(Path.dirname(p))
      File.write!(p, content)
    end

    assert CLI.call(["bundle", src, out], nil) =~ "bundled 4 files"
    assert File.read!(out) =~ "<h1>app</h1>"

    assert CLI.call(["unbundle", out, dst], nil) =~ "unbundled 4 files"

    for {name, content} <- tree do
      assert File.read!(Path.join(dst, name)) == content, "mismatch for #{name}"
    end
  end

  test "write_tree rejects a parts map entry that escapes the target dir", %{base: base} do
    # :zip already sanitizes archive names, so a packed blob can't smuggle a `..`.
    # The path-guard is defense-in-depth on the parts map itself: a hand-built map
    # with a traversal/absolute key must be refused, never written outside `dir`.
    dst = Path.join(base, "dst")

    assert_raise ArgumentError, fn ->
      Workbooks.Bundle.write_tree(%{"../escape.txt" => "pwn"}, dst)
    end

    assert_raise ArgumentError, fn ->
      Workbooks.Bundle.write_tree(%{"/etc/escape.txt" => "pwn"}, dst)
    end

    refute File.exists?(Path.join(base, "escape.txt"))
  end

  test "unbundle raises when the html carries no embedded bundle", %{base: base} do
    out = Path.join(base, "plain.html")
    File.mkdir_p!(base)
    File.write!(out, "<html><body>nothing</body></html>")

    assert_raise RuntimeError, ~r/no wb-bundle/, fn ->
      CLI.call(["unbundle", out, Path.join(base, "dst")], nil)
    end
  end
end

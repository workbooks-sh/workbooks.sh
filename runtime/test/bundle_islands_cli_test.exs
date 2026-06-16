defmodule Workbooks.BundleIslandsCliTest do
  @moduledoc """
  End-to-end: the composition-island layer wired into `wb bundle`/`wb unbundle`/
  `wb islands` (docs/WORKBOOK-COMPOSITION-MODEL.md). A real workbook tree
  (agent → toolkit → toolkit + org + vfs) round-trips dir → .html → dir byte-exact
  (the existing Bundle guarantee), the bundled page carries BOTH the wb-bundle zip
  AND the work-islands manifest, and the manifest is a loss-free projection whose
  toolkit DAG resolves identically to the source tree.

  Hermetic: the agent leg runs the REAL embedded OQL kernel (no network/LLM); the
  tree carries its own index.html so `OQL.render` is never invoked.
  """
  use ExUnit.Case, async: false
  alias Workbooks.CLI
  alias Workbooks.Bundle.Islands

  setup do
    base = Path.join(System.tmp_dir!(), "wb_islands_cli_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  @tree %{
    "index.html" => "<!doctype html><html><body><h1>workbook</h1></body></html>",
    "agents/analyst.org" =>
      "* Analyst :agent:\n:PROPERTIES:\n:ID: analyst\n:MODEL: test/model\n:TOOLKITS: crm\n:END:\n** System prompt\nResolve CRM questions.\n",
    "toolkits/crm/manifest.html" =>
      ~s(<work-toolkit id="crm" exec="command" requires="browser, git>=2.30"></work-toolkit>),
    "toolkits/browser/manifest.html" => ~s(<work-toolkit id="browser" exec="command"></work-toolkit>),
    "report.org" => "* Q3\nRevenue is up.\n",
    "data.sqlite" => "SQLite format 3\0demo"
  }

  defp write_tree(src) do
    for {name, content} <- @tree do
      p = Path.join(src, name)
      File.mkdir_p!(Path.dirname(p))
      File.write!(p, content)
    end
  end

  test "wb bundle embeds the islands manifest; unbundle restores byte-exact + reports the structure", %{base: base} do
    src = Path.join(base, "src")
    out = Path.join(base, "wb.html")
    dst = Path.join(base, "dst")
    write_tree(src)

    msg = CLI.call(["bundle", src, out], nil)
    assert msg =~ "bundled 6 files"
    assert msg =~ "5 islands"

    page = File.read!(out)
    # both markers coexist: the filesystem zip AND the declarative structure
    assert page =~ ~s(id="wb-bundle")
    assert page =~ ~s(id="work-islands")
    assert page =~ "<h1>workbook</h1>"

    unmsg = CLI.call(["unbundle", out, dst], nil)
    assert unmsg =~ "unbundled 6 files"
    # the composition summary names the structure
    assert unmsg =~ "agent"
    assert unmsg =~ "toolkit"

    # byte-exact tree restore (the Bundle guarantee, unbroken by the manifest)
    for {name, content} <- @tree do
      assert File.read!(Path.join(dst, name)) == content, "mismatch for #{name}"
    end
  end

  test "the embedded manifest is a loss-free projection of the source tree's islands", %{base: base} do
    src = Path.join(base, "src")
    out = Path.join(base, "wb.html")
    write_tree(src)
    CLI.call(["bundle", src, out], nil)

    from_page = File.read!(out) |> Islands.extract_manifest()
    from_tree = Islands.index(@tree)

    norm = fn list ->
      list |> Enum.map(&Map.take(&1, [:kind, :id, :path, :attrs])) |> Enum.sort_by(&{&1.kind, &1.path})
    end

    assert norm.(from_page) == norm.(from_tree)
  end

  test "the toolkit DAG resolves identically from the bundled manifest as from the tree", %{base: base} do
    src = Path.join(base, "src")
    out = Path.join(base, "wb.html")
    write_tree(src)
    CLI.call(["bundle", src, out], nil)

    islands = File.read!(out) |> Islands.extract_manifest()
    closure = Workbooks.Toolkits.closure(["crm"], Islands.edges(islands), Islands.toolkit_ids(islands))

    assert MapSet.new(closure) == MapSet.new(["crm", "browser"])
  end

  test "wb islands dumps the structure from both a bundled .html and a working dir", %{base: base} do
    src = Path.join(base, "src")
    out = Path.join(base, "wb.html")
    write_tree(src)
    CLI.call(["bundle", src, out], nil)

    from_html = CLI.call(["islands", out], nil)
    assert from_html =~ "5 islands"
    assert from_html =~ "analyst"
    assert from_html =~ "crm"

    from_dir = CLI.call(["islands", src], nil)
    assert from_dir =~ "5 islands"
    assert from_dir =~ "agent"
  end
end

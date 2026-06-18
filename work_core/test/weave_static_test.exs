defmodule WorkCore.WeaveStaticTest do
  use ExUnit.Case, async: true
  alias WorkCore.Weave

  setup do
    dir = Path.join(System.tmp_dir!(), "weave_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "index.work"), """
    # Store

    The catalog and its pricing. See [[pricing]].

    sandbox rust :pricing do
      pub fn total(n: u32) -> u32 { n * 2 }
    end
    """)

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "weaves a .work tree into one self-contained HTML workbook", %{dir: dir} do
    html = Weave.static(dir)

    assert html =~ "<!doctype html>"
    assert html =~ "<title>Store</title>"          # title from the H1
    assert html =~ "<style>"                         # self-contained CSS
    assert html =~ ~s(<work-component lang="rust" name="pricing" kind="sandbox">)
    assert html =~ "pub fn total"                    # the unit source is embedded
    assert html =~ ~s(<a class="ref" href="#pricing">pricing</a>)  # backlink rendered
  end

  test "to_file writes the workbook and reports size", %{dir: dir} do
    out = Path.join(dir, "out.html")
    assert {:ok, ^out, bytes} = Weave.to_file(dir, out)
    assert bytes > 0
    assert File.read!(out) =~ "work-component"
    assert Weave.unit_count(dir) == 1
  end
end

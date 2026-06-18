defmodule Nexus.WeaveTest do
  use ExUnit.Case, async: false

  test "weave renders a workbook folder to one self-contained HTML with inline markdown" do
    dir = Path.join(System.tmp_dir!(), "wv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "page.work"), """
    # Title

    Some **bold** and *italic* and `code` and a [link](https://x.io).

    - one
    - two

    rust :scorer do
      pub extern "C" fn score(x: i32) -> i32 { x }
    end
    """)

    html = Nexus.Weave.weave(dir)

    assert html =~ "<!doctype html>"
    assert html =~ "<h1>Title</h1>"
    assert html =~ "<strong>bold</strong>"
    assert html =~ "<em>italic</em>"
    assert html =~ "<code>code</code>"
    assert html =~ ~s(<a href="https://x.io">link</a>)
    assert html =~ "<li>one</li>"
    assert html =~ ~s(<figure class="unit" data-unit="rust:scorer">)

    File.rm_rf!(dir)
  end

  defp wb(body) do
    dir = Path.join(System.tmp_dir!(), "wv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.work"), body)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp res_of(dir),
    do: dir |> Path.join("a.work") |> File.read!() |> Nexus.Literate.parse() |> Enum.find(&(&1.type == :code)) |> Nexus.Resource.compile()

  test "`show Resource` renders a live data table from the Store, columns from __fields__" do
    dir = wb("resource Item do\n  name :text\n  price :int\nend\n\nshow Item\n")
    mod = res_of(dir)
    Nexus.Store.clear(mod)
    Nexus.Store.create(mod, %{name: "Bread", price: 350})

    html = Nexus.Weave.weave(dir)
    assert html =~ ~s(<table class="data" data-resource="Item">)
    assert html =~ "<th>name</th>" and html =~ "<th>price</th>"
    assert html =~ "Bread" and html =~ "350"
  end

  test "data cells are XSS-escaped" do
    dir = wb("resource Item do\n  name :text\nend\n\nshow Item\n")
    mod = res_of(dir)
    Nexus.Store.clear(mod)
    Nexus.Store.create(mod, %{name: "<script>alert(1)</script>"})

    html = Nexus.Weave.weave(dir)
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>alert(1)"
  end

  test "an empty resource renders a graceful empty-state, not a crash" do
    dir = wb("resource Item do\n  name :text\nend\n\nshow Item\n")
    Nexus.Store.clear(res_of(dir))
    html = Nexus.Weave.weave(dir)
    assert html =~ "no rows yet"
  end

  test "show of an unknown resource degrades gracefully" do
    dir = wb("# Page\n\nshow Ghost\n")
    html = Nexus.Weave.weave(dir)
    assert html =~ "unknown resource"
    assert html =~ "Ghost"
  end
end

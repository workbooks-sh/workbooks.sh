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

  @tag :compiler
  @tag timeout: 360_000
  test "show <Unit> bakes the unit's render() output into the page, across rust/c/zig" do
    if File.dir?("../runtime/compilers") && System.find_executable("wasm-tools") do
      cases = [
        {"c :cu do\n  int render(void) { return 6 * 7; }\nend\n\nshow cu\n", "42"},
        {"zig :zu do\n  export fn render() i32 { return 5 * 9; }\nend\n\nshow zu\n", "45"},
        {"rust :ru do\n  #[no_mangle]\n  pub extern \"C\" fn render() -> i32 { 8 * 8 }\nend\n\nshow ru\n", "64"}
      ]

      for {body, expected} <- cases do
        dir = Path.join(System.tmp_dir!(), "wvu_#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "index.work"), "# R\n\n" <> body)
        html = Nexus.Weave.weave(dir)
        assert html =~ "unit-output", "no unit-output for: #{body}"
        assert html =~ ">#{expected}<", "expected #{expected} baked for: #{body}"
        File.rm_rf!(dir)
      end
    else
      :ok
    end
  end

  test "the index file leads, gives the title, and a multi-file workbook gets a nav" do
    dir = Path.join(System.tmp_dir!(), "wvc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "zlast.work"), "## Pricing\n\nlast file\n")
    File.write!(Path.join(dir, "index.work"), "# Corner Store\n\nthe index leads\n")
    on_exit(fn -> File.rm_rf!(dir) end)

    html = Nexus.Weave.weave(dir)
    assert html =~ "<title>Corner Store</title>"
    assert :binary.match(html, "the index leads") |> elem(0) < (:binary.match(html, "last file") |> elem(0))
    assert html =~ "wb-nav" and html =~ ~s(href="#index-work")
  end
end

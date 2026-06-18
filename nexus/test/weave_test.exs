defmodule Nexus.WeaveTest do
  use ExUnit.Case, async: true

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
end

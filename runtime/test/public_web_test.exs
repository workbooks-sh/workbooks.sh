defmodule Workbooks.PublicWebTest do
  use ExUnit.Case, async: true

  # friction #10 (lander-live): a complete HTML document is served verbatim,
  # while org-source still gets the kernel render + doc shell.
  describe "static_page/2" do
    test "serves a complete HTML document verbatim (no double-wrap)" do
      html = "<!doctype html><html lang=\"en\"><head><title>Mine</title></head><body>hi</body></html>"
      assert Workbooks.PublicWeb.static_page("app", html) == html
    end

    test "is case/whitespace tolerant about the doctype" do
      html = "\n  <!DOCTYPE HTML><html><body>x</body></html>"
      assert Workbooks.PublicWeb.static_page("app", html) == html
    end

    test "org-source is rendered and wrapped in the doc shell" do
      out = Workbooks.PublicWeb.static_page("doc", "* Heading\nbody")
      assert String.contains?(out, "Rendered by the Workbooks OQL kernel")
      assert String.contains?(out, "<title>doc</title>")
    end
  end
end

defmodule Nexus.Browse.PageTest do
  use ExUnit.Case, async: true
  alias Nexus.Browse.Page

  test "parses links, resolving relative/absolute/root-relative against the base" do
    html = """
    <a href="/about">About</a>
    <a href="contact.html">Contact us</a>
    <a href="https://other.com/x">External</a>
    <a href="#frag">skip-fragment</a>
    <a href="javascript:void(0)">skip-js</a>
    """

    %{links: links} = Page.parse(html, "https://site.com/dir/page")
    hrefs = Enum.map(links, & &1.href)
    assert "https://site.com/about" in hrefs
    assert "https://site.com/dir/contact.html" in hrefs
    assert "https://other.com/x" in hrefs
    refute Enum.any?(links, &String.starts_with?(&1.href, "javascript:"))
  end

  test "parses forms with method, action, and named fields" do
    html = """
    <form action="/search" method="GET">
      <input type="text" name="q" value="">
      <input type="hidden" name="lang" value="en">
      <button>Go</button>
    </form>
    """

    %{forms: [form]} = Page.parse(html, "https://site.com/")
    assert form.method == "get"
    assert form.action == "https://site.com/search"
    assert Enum.map(form.fields, & &1.name) == ["q", "lang"]
    assert Enum.find(form.fields, &(&1.name == "lang")).value == "en"
  end

  test "abs resolves the spectrum of URL forms" do
    assert Page.abs("https://x.io/a", "https://b.io/") == "https://x.io/a"
    assert Page.abs("//cdn.io/x", "https://b.io/") == "https://cdn.io/x"
    assert Page.abs("/root", "https://b.io/deep/page") == "https://b.io/root"
    assert Page.abs("rel", "https://b.io/deep/page") == "https://b.io/deep/rel"
  end
end

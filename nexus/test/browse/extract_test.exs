defmodule Nexus.Browse.ExtractTest do
  @moduledoc "Regression: the title accumulates as an iolist; tidy/1 must coerce it (else String.replace/4 crashes)."
  use ExUnit.Case, async: true
  alias Nexus.Browse.Extract

  test "read/2 returns a binary title + text and never crashes on an iolist title" do
    html =
      "<html><head><title>Example Domain</title></head>" <>
        "<body><h1>Example Domain</h1><p>For documentation examples.</p></body></html>"

    r = Extract.read(html, "https://example.com")

    assert is_binary(r.title) and r.title == "Example Domain"
    assert is_binary(r.text) and r.text =~ "documentation"
    assert is_binary(r.markdown)
  end

  test "an og:title (also iolist) is tidied to a binary, not crashed" do
    html =
      ~s(<html><head><meta property="og:title" content="OG  Title"><title>fallback</title></head>) <>
        "<body><p>hi</p></body></html>"

    r = Extract.read(html, "https://example.com")
    assert is_binary(r.title)
  end
end

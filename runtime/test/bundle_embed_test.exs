defmodule Workbooks.BundleEmbedTest do
  @moduledoc """
  Pins the self-contained Workbook primitive: a workbook's filesystem bundle lives
  INSIDE the .html as a base64 `<script id="wb-bundle">` block (the zip is already
  deflate-compressed per entry). Round-trips tree -> zip -> embed -> extract ->
  unzip -> tree byte-exact, is idempotent across the edit loop, and the base64
  payload can't break out of the script tag. Deterministic — no network/LLM.
  """
  use ExUnit.Case, async: true
  alias Workbooks.Bundle

  test "extract ∘ embed round-trips a blob byte-exact; the page survives" do
    blob = :crypto.strong_rand_bytes(2048)
    html = "<!doctype html><html><body><h1>wb</h1></body></html>"
    out = Bundle.embed(html, blob)

    assert Bundle.embedded?(out)
    assert Bundle.extract(out) == blob
    assert out =~ "<h1>wb</h1>"
    assert out =~ "</body>"
  end

  test "full tree round-trip: parts -> pack -> embed -> extract -> unpack == parts" do
    parts = %{
      "workspace.org" => "* Hello\nintro\n",
      "data/blob.bin" => :crypto.strong_rand_bytes(4096),
      "src/app.svelte" => "<h1>{count}</h1>"
    }

    html = Bundle.embed("<html><body>page</body></html>", Bundle.pack(parts))
    assert Bundle.unpack(Bundle.extract(html)) == parts
  end

  test "embed is idempotent — re-bundling replaces the prior payload (edit loop)" do
    html = "<html><body>p</body></html>"
    once = Bundle.embed(html, "AAAA")
    twice = Bundle.embed(once, "BBBB")

    assert Bundle.extract(twice) == "BBBB"
    assert length(Regex.scan(~r/id="wb-bundle"/, twice)) == 1
  end

  test "base64 payload cannot break out of the <script> tag (injection-inert)" do
    # A blob whose bytes literally spell a closing tag + script — must survive
    # intact and never terminate the wb-bundle block early.
    blob = "</script><script>alert(1)</script>" <> :crypto.strong_rand_bytes(64)
    html = Bundle.embed("<html><body></body></html>", blob)

    assert Bundle.extract(html) == blob
  end

  test "extract returns nil when there's no embedded bundle" do
    assert Bundle.extract("<html><body>nothing here</body></html>") == nil
    refute Bundle.embedded?("<html></html>")
  end

  test "no </body>: the block is appended and still round-trips" do
    out = Bundle.embed("<div>fragment</div>", "ZZ")
    assert Bundle.extract(out) == "ZZ"
  end
end

defmodule Workbooks.BundleLoaderTest do
  @moduledoc """
  Pins the browser hydration loader: the served-page shell carries it, and
  `embed_loader/1` makes a CLI-built .html self-contained offline. Asserts the
  loader is PRESENT and WELL-FORMED (classic script, no leftover ESM syntax, the
  load algorithm intact) — the bytes a browser will run, checked without a browser.
  Deterministic — no network/LLM/zip round-trip (the JS round-trip is unit-tested
  by `web/wb-bundle-loader.test.js` under node --test).
  """
  use ExUnit.Case, async: true
  alias Workbooks.Bundle
  alias Workbooks.PublicWeb

  test "loader_block is a well-formed classic script with the full hydrate algorithm" do
    block = Bundle.loader_block()

    # Classic <script> (no type=module) so it runs from file:// offline.
    assert block =~ ~s(<script id="wb-bundle-loader">)
    assert block =~ "</script>"
    refute block =~ "type=\"module\""

    # ESM `export ` must be stripped for a classic script (and there were no imports).
    refute block =~ ~r/^export /m
    refute block =~ ~r/^\s*import /m

    # The load algorithm survives intact: read block, base64-decode, walk the zip,
    # inflate per-entry with deflate-raw, dispatch the consumed event.
    assert block =~ ~s|getElementById("wb-bundle")|
    assert block =~ "atob("
    assert block =~ ~s|DecompressionStream("deflate-raw")|
    assert block =~ "wb:hydrated"
    # EOCD / central-dir / local-header signatures the parser scans for.
    assert block =~ "0x06054b50"
    assert block =~ "0x02014b50"
    assert block =~ "0x04034b50"
  end

  test "served static_doc page carries the loader before </body>" do
    html = PublicWeb.static_doc("demo", "<p>rendered</p>")

    assert html =~ ~s(<script id="wb-bundle-loader">)
    assert html =~ "wb:hydrated"
    # The loader rides before the body close, after the rendered content.
    [before_body | _] = String.split(html, "</body>")
    assert before_body =~ "wb-bundle-loader"
    assert before_body =~ "<p>rendered</p>"
  end

  test "embed_loader makes an offline page self-contained and is idempotent" do
    html = "<!doctype html><html><body><h1>wb</h1></body></html>"

    out = Bundle.embed_loader(html)
    assert Bundle.has_loader?(out)
    assert out =~ "<h1>wb</h1>"
    assert out =~ "</body>"
    # Loader sits inside the body.
    assert String.contains?(out, ~s(<script id="wb-bundle-loader">)) and
             String.split(out, "</body>") |> hd() =~ "wb-bundle-loader"

    # Re-embedding replaces, never stacks — the edit loop stays clean.
    twice = Bundle.embed_loader(out)
    assert length(String.split(twice, ~s(<script id="wb-bundle-loader">))) == 2
  end

  test "embed_loader composes with embed: one .html with both bundle + loader" do
    html = "<!doctype html><html><body><h1>wb</h1></body></html>"
    blob = :crypto.strong_rand_bytes(256)

    out = html |> Bundle.embed(blob) |> Bundle.embed_loader()

    assert Bundle.embedded?(out)
    assert Bundle.extract(out) == blob
    assert Bundle.has_loader?(out)
  end
end

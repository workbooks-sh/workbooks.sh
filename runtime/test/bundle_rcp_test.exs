defmodule Workbooks.BundleRcpTest do
  @moduledoc """
  Pins the BYTES-over-RCP bundle seam the desktop (and any off-engine caller)
  uses: `POST /rcp/bundle` packs a raw parts map → self-contained .html, and
  `POST /rcp/unbundle` extracts it back to a parts map — byte-exact, binary-safe.
  The desktop owns NO bundler; this is `Workbooks.Bundle` on the engine, the same
  home as `work bundle`. Mirrors the checkout/checkin precedent (the engine runs in
  a container, so trees move as bytes, never as engine-side paths).

  Deterministic (Plug.Test; x-tenant dev auth; the tree carries its own
  index.html so OQL.render is never invoked).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  defp post(path, body, tenant \\ "local") do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-tenant", tenant)
    |> Workbooks.Web.call(Workbooks.Web.init([]))
  end

  test "bundle → unbundle round-trips a parts map byte-exact (binary-safe)" do
    blob = :crypto.strong_rand_bytes(4096)

    tree = %{
      "index.html" => "<!doctype html><html><body><h1>app</h1></body></html>",
      "data/blob.bin" => blob,
      "src/app.svelte" => "<h1>{count}</h1>\n",
      "workspace.org" => "* Hello\nintro\n"
    }

    files = Map.new(tree, fn {k, v} -> {k, Base.encode64(v)} end)

    bconn = post("/rcp/bundle", %{files: files})
    assert bconn.status == 200
    bbody = Jason.decode!(bconn.resp_body)
    assert bbody["ok"]
    assert Enum.sort(bbody["files"]) == Enum.sort(Map.keys(tree))

    html = Base.decode64!(bbody["html_b64"])
    # The page survives, the bundle is embedded, and the hydration loader is inlined.
    assert html =~ "<h1>app</h1>"
    assert Workbooks.Bundle.embedded?(html)
    assert Workbooks.Bundle.has_loader?(html)

    uconn = post("/rcp/unbundle", %{b64: Base.encode64(html)})
    assert uconn.status == 200
    ubody = Jason.decode!(uconn.resp_body)
    assert ubody["ok"]

    got = Map.new(ubody["files"], fn {k, v} -> {k, Base.decode64!(v)} end)
    assert got == tree
  end

  test "bundle with sign=1 embeds a verifiable tenant C2PA manifest (not an ad-hoc comment)" do
    files = %{
      "index.html" => Base.encode64("<!doctype html><html><body>ok</body></html>")
    }

    conn = post("/rcp/bundle?sign=1", %{files: files})
    assert conn.status == 200
    html = conn.resp_body |> Jason.decode!() |> Map.fetch!("html_b64") |> Base.decode64!()

    # The egress is the canonical signed form: a C2PA manifest, NOT the legacy
    # `<!-- wb-signature -->` comment the desktop used to append.
    refute html =~ "wb-signature:"
    assert html =~ "wb-c2pa-manifest"

    # The manifest is well-formed and asset-bound (the asset half needs no key).
    v = Workbooks.Manifest.verify(html)
    refute Map.has_key?(v, :error)
    assert v.asset_integrity
    assert is_binary(v.issuer_did)
  end

  test "unbundle on html with no embedded bundle → error shape (no crash)" do
    plain = Base.encode64("<html><body>nothing</body></html>")
    conn = post("/rcp/unbundle", %{b64: plain})
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["error"] =~ "no wb-bundle"
  end
end

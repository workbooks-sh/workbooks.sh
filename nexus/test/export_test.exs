defmodule Nexus.ExportTest do
  @moduledoc """
  wb-jr1py.12: Nexus.Export — static multi-page export through the real Nexus.SSR.render seam.
  Route enumeration, per-route files + 404 shell, base injection, asset copy exclusions,
  hybrid origin rewrite + proxy manifest, and the .work (never JSON) manifest artifact.
  """
  use ExUnit.Case, async: true

  defp surface_fixture do
    root = Path.join(System.tmp_dir!(), "export-src-#{System.unique_integer([:positive])}")
    out = Path.join(System.tmp_dir!(), "export-out-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root); File.rm_rf!(out) end)

    File.write!(Path.join(root, "index.work"), """
    # Shop

    facet app

    app :site do
      title "Shop"
      page "/", "home"
      page "/about", "about"
      page "/orders/:id", "order"
    end
    """)

    File.write!(Path.join(root, "home.work"), "# Home\n\nWelcome to the shop.\n")
    File.write!(Path.join(root, "about.work"), "# About\n\nWe sell things.\n")
    File.write!(Path.join(root, "order.work"), "# Order\n\nOne order.\n")

    # assets + things that must NOT ship
    File.mkdir_p!(Path.join(root, "img"))
    File.write!(Path.join(root, "img/logo.svg"), "<svg/>")
    File.write!(Path.join(root, "store.db"), "sqlite-bytes")
    File.write!(Path.join(root, "store.db-wal"), "wal")
    File.mkdir_p!(Path.join(root, ".nexus"))
    File.write!(Path.join(root, ".nexus/runtime"), "state")
    File.mkdir_p!(Path.join(root, "node_modules/x"))
    File.write!(Path.join(root, "node_modules/x/y.js"), "junk")

    {root, out}
  end

  test "SSR.routes enumerates the app page table; a document surface is one page" do
    {root, _out} = surface_fixture()
    assert [%{path: "/"}, %{path: "/about"}, %{path: "/orders/:id"}] = Nexus.SSR.routes(root)

    doc = Path.join(System.tmp_dir!(), "export-doc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(doc)
    on_exit(fn -> File.rm_rf!(doc) end)
    File.write!(Path.join(doc, "index.work"), "# Doc\n\nfacet app\n\nJust prose.\n")
    assert [%{path: "/", file: nil}] = Nexus.SSR.routes(doc)
  end

  test "static export: one file per literal route, 404 shell, base href, all routes embedded" do
    {root, out} = surface_fixture()
    assert {:ok, m} = Nexus.Export.surface(root, out)

    assert File.exists?(Path.join(out, "index.html"))
    assert File.exists?(Path.join(out, "about/index.html"))
    assert File.exists?(Path.join(out, "404.html"))
    # a param route gets no file of its own — the 404 shell serves it
    refute File.exists?(Path.join(out, "orders"))
    assert m.param_routes == ["/orders/:id"]

    home = File.read!(Path.join(out, "index.html"))
    about = File.read!(Path.join(out, "about/index.html"))

    assert home =~ ~s(<base href="/">)
    # every page embeds ALL routes + the client router; only the matched one is visible
    assert home =~ ~s(data-route="/about" hidden)
    assert home =~ ~s(data-route="/")
    assert about =~ ~s(data-route="/about">)
    assert about =~ "We sell things."

    # static mode: no origin callback rewrite, no proxy list
    assert m.proxy == []
    refute home =~ "fetch('http"
  end

  test "asset copy honors the serve_static exclusions" do
    {root, out} = surface_fixture()
    assert {:ok, m} = Nexus.Export.surface(root, out)

    assert File.exists?(Path.join(out, "img/logo.svg"))
    assert "img/logo.svg" in m.assets

    refute File.exists?(Path.join(out, "store.db"))
    refute File.exists?(Path.join(out, "store.db-wal"))
    refute File.exists?(Path.join(out, ".nexus"))
    refute File.exists?(Path.join(out, "node_modules"))
    # sources never ship in the bundle
    refute File.exists?(Path.join(out, "index.work"))
    refute File.exists?(Path.join(out, "home.work"))
  end

  test "hybrid export needs an origin and rewrites the data shim to it; manifest carries proxy list" do
    {root, out} = surface_fixture()
    assert {:error, :hybrid_needs_origin} = Nexus.Export.surface(root, out, mode: :hybrid)

    assert {:ok, m} = Nexus.Export.surface(root, out, mode: :hybrid, origin: "https://shop.fly.dev/")
    assert m.proxy == ["/data", "/live", "/ws", "/api"]
    assert m.origin == "https://shop.fly.dev"

    # The nexus.data shim lives on DOCUMENT surfaces (an app site's islands call relative paths that
    # the worker proxy list covers) — assert the origin rewrite on a document surface carrying it.
    doc = Path.join(System.tmp_dir!(), "export-hyb-#{System.unique_integer([:positive])}")
    doc_out = Path.join(System.tmp_dir!(), "export-hyb-out-#{System.unique_integer([:positive])}")
    File.mkdir_p!(doc)
    on_exit(fn -> File.rm_rf!(doc); File.rm_rf!(doc_out) end)
    File.write!(Path.join(doc, "index.work"), "# Doc\n\nfacet app\n\nProse page.\n")

    assert {:ok, _} = Nexus.Export.surface(doc, doc_out, mode: :hybrid, origin: "https://shop.fly.dev")
    html = File.read!(Path.join(doc_out, "index.html"))

    assert html =~ "nexus.data"
    assert html =~ "fetch('https://shop.fly.dev/data/'"
    refute html =~ "fetch('data/'"
  end

  test "manifest artifact is a .work block (never JSON) + _headers emitted" do
    {root, out} = surface_fixture()
    assert {:ok, _} = Nexus.Export.surface(root, out)

    manifest = File.read!(Path.join(out, "export.manifest.work"))
    assert manifest =~ "export do"
    assert manifest =~ ~s(mode="static")
    assert manifest =~ ~s(pages="/ /about")
    refute File.exists?(Path.join(out, "manifest.json"))

    headers = File.read!(Path.join(out, "_headers"))
    assert headers =~ "immutable"
  end

  test "unknown mode + missing surface fail closed" do
    {root, out} = surface_fixture()
    assert {:error, {:unknown_mode, :weird}} = Nexus.Export.surface(root, out, mode: :weird)
    assert {:error, :no_surface} = Nexus.Export.surface(Path.join(root, "nope"), out)
  end
end

defmodule Nexus.Export do
  @moduledoc """
  Static multi-page EXPORT of a mounted surface (wb-jr1py.12) — the artifact of the
  agents-manage-apps reshape. Renders the workbook at `root` through the SAME `Nexus.SSR.render/2`
  seam the live server uses (one HTML file per declared route), copies the surface's static
  assets, and returns a manifest — a bundle deployable to any static host (Cloudflare Pages, or
  Workers+R2 via the cloudflare deploy recipe). `work weave` stays single-doc by design — a SITE
  is a nexus concern (weave.zig:6-7), and this is where the nexus renders one to disk.

  Modes:
    * `:static` (default) — bake the data islands (`live: false, bake: true`): zero origin
      callback; the bundle works fully offline.
    * `:hybrid` — live posture (`live: true, bake: false`): pages fetch `/data/:resource` fresh.
      Requires `:origin` (the nexus base URL); the known shim call sites are rewritten to absolute
      origin URLs and the manifest carries the `proxy` list (`/data /live /ws /api`) an edge
      worker should route back to the origin.

  Every exported page embeds ALL routes (hidden) + the client history router — `Nexus.SSR`'s
  multi-page shape — so any one file can serve any in-app navigation without another fetch, and
  `404.html` (the root shell) is the static-host fallback that makes param deep links
  (`/orders/:id`) land correctly.

  The manifest is returned as data and written as `export.manifest.work` (a `.work` block —
  never a JSON sidecar).
  """

  # The live-nexus paths a hybrid bundle's edge worker must proxy to origin.
  @proxy_paths ~w(/data /live /ws /api)

  # Never in the bundle: sources (behind /source on a live nexus), runtime data, databases.
  @excluded_exts ~w(.work .db)
  @excluded_dirs ~w(node_modules)

  @doc """
  Export the surface at `root` into `out_dir`. Options: `:mode` (`:static` | `:hybrid`),
  `:origin` (hybrid), `:tenant` (static bake), `:base` (`<base href>`, default "/").
  `{:ok, manifest} | {:error, reason}`.
  """
  def surface(root, out_dir, opts \\ []) do
    mode = Keyword.get(opts, :mode, :static)
    origin = opts[:origin] && String.trim_trailing(opts[:origin], "/")

    cond do
      not File.dir?(root) -> {:error, :no_surface}
      mode not in [:static, :hybrid] -> {:error, {:unknown_mode, mode}}
      mode == :hybrid and origin in [nil, ""] -> {:error, :hybrid_needs_origin}
      true -> {:ok, do_export(root, out_dir, mode, origin, opts)}
    end
  end

  defp do_export(root, out, mode, origin, opts) do
    File.mkdir_p!(out)
    tenant = Keyword.get(opts, :tenant, Nexus.Store.default_tenant())
    base = Keyword.get(opts, :base, "/")
    routes = Nexus.SSR.routes(root)

    render = fn path ->
      case mode do
        :static -> Nexus.SSR.render(root, route: path, live: false, bake: true, tenant: tenant)
        :hybrid -> Nexus.SSR.render(root, route: path, live: true, bake: false)
      end
      |> inject_base(base)
      |> rewrite_origin(mode, origin)
    end

    # One file per LITERAL route; param routes (`/orders/:id`) have no static file of their own —
    # the 404 fallback shell (every page embeds all routes + the router) serves them.
    pages =
      for %{path: path} <- routes, not String.contains?(path, ":") do
        file = page_file(out, path)
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, render.(path))
        %{path: path, file: Path.relative_to(file, out)}
      end

    File.write!(Path.join(out, "404.html"), render.("/"))
    assets = copy_assets(root, out)
    write_headers(out)

    manifest = %{
      mode: mode,
      origin: origin,
      base: base,
      pages: pages,
      param_routes: for(%{path: p} <- routes, String.contains?(p, ":"), do: p),
      assets: assets,
      proxy: if(mode == :hybrid, do: @proxy_paths, else: [])
    }

    File.write!(Path.join(out, "export.manifest.work"), manifest_work(manifest))
    manifest
  end

  defp page_file(out, "/"), do: Path.join(out, "index.html")
  defp page_file(out, path), do: Path.join([out, String.trim_leading(path, "/"), "index.html"])

  # Exported pages live at nested URLs (`/about/`), so author-relative asset refs need a fixed base.
  defp inject_base(html, base),
    do: String.replace(html, "<head>", ~s(<head><base href="#{base}">), global: false)

  # Hybrid: the js shim fetches relative `data/…` (ssr.ex js_shim) — point it at the origin nexus.
  # Author islands that call other live paths are covered by the manifest's proxy list instead.
  defp rewrite_origin(html, :hybrid, origin), do: String.replace(html, "fetch('data/'", "fetch('#{origin}/data/'")
  defp rewrite_origin(html, _mode, _origin), do: html

  # The bundle's static files = every regular file under root MINUS sources (.work), databases
  # (+ WAL/SHM sidecars), dot-paths (runtime data like .nexus/), node_modules, TEMPLATE.work.
  # Mirrors what serve_static will and won't serve (server.ex:1190-1231).
  defp copy_assets(root, out) do
    for f <- Path.wildcard(Path.join(root, "**/*")),
        File.regular?(f),
        rel = Path.relative_to(f, root),
        asset?(rel) do
      dest = Path.join(out, rel)
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(f, dest)
      rel
    end
  end

  defp asset?(rel) do
    segs = Path.split(rel)
    ext = Path.extname(rel)

    not Enum.any?(segs, &String.starts_with?(&1, ".")) and
      not Enum.any?(segs, &(&1 in @excluded_dirs)) and
      ext not in @excluded_exts and
      not String.ends_with?(rel, "-wal") and
      not String.ends_with?(rel, "-shm")
  end

  # CF-Pages-style header rules: HTML revalidates (the deploy is the invalidation), assets cache.
  defp write_headers(out) do
    File.write!(Path.join(out, "_headers"), """
    /*
      Cache-Control: public, max-age=0, must-revalidate
    /*.css
      Cache-Control: public, max-age=31536000, immutable
    /*.js
      Cache-Control: public, max-age=31536000, immutable
    /*.woff2
      Cache-Control: public, max-age=31536000, immutable
    /*.png
      Cache-Control: public, max-age=86400
    /*.jpg
      Cache-Control: public, max-age=86400
    /*.svg
      Cache-Control: public, max-age=86400
    """)
  end

  # The manifest as a .work block document (blocks are the source of truth — never a JSON sidecar).
  defp manifest_work(m) do
    """
    # Export manifest (written by Nexus.Export)

    export do
      mode="#{m.mode}"#{if m.origin, do: ~s(\n  origin="#{m.origin}"), else: ""}
      base="#{m.base}"
      pages="#{Enum.map_join(m.pages, " ", & &1.path)}"#{if m.param_routes != [], do: ~s(\n  param-routes="#{Enum.join(m.param_routes, " ")}"), else: ""}#{if m.proxy != [], do: ~s(\n  proxy="#{Enum.join(m.proxy, " ")}"), else: ""}
      assets="#{length(m.assets)}"
    end
    """
  end
end

defmodule Workbooks.PublicWeb do
  @moduledoc """
  The PUBLIC content plane (wb-1x1, PUBLIC-WEB-PLAN.org) — a SECOND, separate HTTP
  surface from `Workbooks.Web` (the authed control plane). This router is anonymous
  by design and serves ONE thing: the static, self-contained bytes of a published
  app, resolved by HOST.

  Hard isolation rules (the whole point of the plane split):
    * NO `Workbooks.Auth` plug — public, unauthenticated.
    * GET only — no writes, no Dock (`/w/:id/call`), no commands/build/agents, no
      secret access. None of those routes exist here, and this module never calls
      into them.
    * The page served carries NO call-home script to the control plane (unlike
      `Web.workbook_page/2`); it is static published content. Server-side compute
      for a public app is a later phase (the `:public` Policy profile).

  Resolution (P0): HOST's first DNS label IS the app id (e.g. `demo.apps.example`
  → workbook "demo"), read from the existing published store. P1 replaces this with
  the `Workbooks.Domains` registry (host → app, custom domains, TLS).
  """
  use Plug.Router

  # Every public-plane response self-identifies (the honest "served by workbooks"
  # marker — visible in response headers; HTML bodies also carry a view-source comment).
  plug(:mark)
  plug(:match)
  plug(:dispatch)

  @marker "<!-- Served by the Workbooks runtime — public content plane (github.com/workbooks-sh) -->"

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  # GET any path → serve the host's app. Non-GET never matches a `get` clause and
  # falls through to the 404 below — no writes, no Dock on this plane.
  get "/*_glob" do
    serve(conn)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp mark(conn, _),
    do: Plug.Conn.register_before_send(conn, &Plug.Conn.put_resp_header(&1, "x-served-by", "workbooks-runtime"))

  defp serve(conn) do
    case app_id(conn) do
      nil ->
        send_resp(conn, 404, "no app for host")

      app ->
        dir = site_dir(app)

        cond do
          File.dir?(dir) -> serve_static(conn, dir)
          (org = Workbooks.ControlPlane.get_workbook(app)) -> serve_html(conn, static_page(app, org))
          true -> send_resp(conn, 404, "no app for host")
        end
    end
  end

  # Serve a file from the host's published static site dir (build/public/<app>/),
  # with index.html as the directory default. Path-traversal safe: ".." segments
  # are rejected AND the resolved path is contained within the site dir.
  defp serve_static(conn, dir) do
    with {:ok, rel} <- safe_rel(conn.request_path),
         path <- index_default(Path.join(dir, rel)),
         true <- contained?(dir, path) and File.regular?(path) do
      ctype = MIME.from_path(path)

      if String.starts_with?(ctype, "text/html") do
        serve_html(conn, inject_marker(File.read!(path)))
      else
        conn |> put_resp_content_type(ctype) |> send_file(200, path)
      end
    else
      _ -> send_resp(conn, 404, "not found")
    end
  end

  defp serve_html(conn, body),
    do: conn |> put_resp_content_type("text/html") |> send_resp(200, inject_marker(body))

  defp site_dir(app), do: Path.join([File.cwd!(), "build", "public", app])

  defp index_default(path), do: if(File.dir?(path), do: Path.join(path, "index.html"), else: path)

  # Reject any ".." segment; return the cleaned relative path.
  defp safe_rel(request_path) do
    segs = request_path |> String.split("/", trim: true)
    if Enum.any?(segs, &(&1 == "..")), do: :error, else: {:ok, Enum.join(segs, "/")}
  end

  # The resolved path must live inside the site dir (defense vs traversal/symlinks).
  defp contained?(dir, path) do
    base = Path.expand(dir)
    full = Path.expand(path)
    full == base or String.starts_with?(full, base <> "/")
  end

  defp inject_marker(html) do
    cond do
      String.contains?(html, @marker) -> html
      String.contains?(html, "</head>") -> String.replace(html, "</head>", "#{@marker}</head>", global: false)
      true -> @marker <> "\n" <> html
    end
  end

  # HOST → app id via the Domains registry (a registered host wins; otherwise it
  # falls back to the leftmost DNS label). conn.host is already port-stripped by Plug.
  defp app_id(conn), do: Workbooks.Domains.resolve(conn.host)

  @doc """
  A STATIC, self-contained page for the public plane: the rendered workbook with no
  backend call-home (contrast `Web.workbook_page/2`, which wires fetch/WS to the
  authed control plane). Public content is bytes only.
  """
  def static_page(id, org) do
    rendered = Workbooks.OQL.render(org)

    """
    <!doctype html><html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>#{escape(id)}</title>
    <style>body{font:15px/1.6 system-ui,sans-serif;max-width:720px;margin:2rem auto;padding:0 1rem;color:#222}
    pre{background:#f6f7f9;padding:.6rem .8rem;border-radius:6px;overflow:auto}</style></head>
    <body><main id="app">#{rendered}</main></body></html>
    """
  end

  defp escape(s) do
    s
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end

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
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@300;400;600&family=Geist+Mono:wght@400;500&display=swap">
    <style>
    :root{--bg:#1a1a1f;--surface:#25252b;--fg:#f4f4f5;--line:rgba(244,244,245,.06);--divider:rgba(244,244,245,.12);--muted:rgba(244,244,245,.55);--dim:rgba(244,244,245,.40);--ok:#34d399;--sans:"Geist",system-ui,-apple-system,sans-serif;--mono:"Geist Mono",ui-monospace,SFMono-Regular,Menlo,monospace}
    @media(prefers-color-scheme:light){:root{--bg:#f7f7f8;--surface:#fff;--fg:#1a1a1f;--line:rgba(26,26,31,.07);--divider:rgba(26,26,31,.12);--muted:rgba(26,26,31,.58);--dim:rgba(26,26,31,.42);--ok:#059669}}
    *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
    html{-webkit-text-size-adjust:100%}
    body{background:var(--bg);color:var(--fg);font-family:var(--sans);font-weight:300;line-height:1.55;letter-spacing:-.005em;-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
    main{max-width:720px;margin:0 auto;padding:0 24px 4rem}
    header{padding:clamp(4rem,12vh,7rem) 0 clamp(2.5rem,6vh,4rem);border-bottom:1px solid var(--divider);margin-bottom:clamp(2rem,5vh,3rem)}
    header p.eyebrow{font-family:var(--mono);font-size:.8rem;letter-spacing:.02em;color:var(--muted);margin-bottom:1.2rem}
    header h1{font-size:clamp(2rem,6vw,3.2rem);font-weight:600;line-height:1.06;letter-spacing:-.025em}
    h2{font-size:1.2rem;font-weight:600;letter-spacing:-.015em;margin:clamp(2.5rem,6vh,3.5rem) 0 .8rem;padding-top:clamp(2rem,5vh,2.6rem);border-top:1px solid var(--divider)}
    h2:first-of-type{margin-top:0;padding-top:0;border-top:0}
    h3{font-family:var(--mono);font-size:.82rem;font-weight:500;letter-spacing:.02em;color:var(--muted);text-transform:uppercase;margin:1.8rem 0 .5rem}
    p{max-width:64ch;font-size:1.05rem;margin-bottom:.9rem}
    a{color:var(--fg);text-underline-offset:3px}
    a:hover{color:var(--muted)}
    code{font-family:var(--mono);font-size:.87em;background:var(--surface);border:1px solid var(--line);border-radius:4px;padding:.1em .35em}
    pre{background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:1.1rem 1.3rem;overflow-x:auto;margin:1.1rem 0}
    pre code{font-size:.84rem;line-height:1.75;background:none;border:none;padding:0}
    table{width:100%;border-collapse:collapse;font-size:.92rem;margin:1.4rem 0}
    th{font-family:var(--mono);font-size:.76rem;font-weight:500;letter-spacing:.03em;text-transform:uppercase;color:var(--muted);text-align:left;padding:.5rem .75rem;border-bottom:1px solid var(--divider)}
    td{padding:.55rem .75rem;border-bottom:1px solid var(--line);vertical-align:top}
    td code{font-size:.82em}
    footer{margin-top:clamp(3rem,7vh,4.5rem);padding:2rem 0 3rem;border-top:1px solid var(--divider);font-size:.82rem;color:var(--dim);letter-spacing:.01em}
    </style></head>
    <body><main>
    <header>
      <p class="eyebrow">workbooks.sh · documentation</p>
      <h1>#{escape(id)}</h1>
    </header>
    #{rendered}
    <footer>Rendered by the Workbooks OQL kernel · <a href="https://github.com/workbooks-sh/workbooks.sh">workbooks-sh/workbooks.sh</a></footer>
    </main></body></html>
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

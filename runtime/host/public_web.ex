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

  @doc """
  Multi-page site variant of static_page. Takes pre-rendered body HTML, pre-built
  nav HTML (sidebar), the current page's relative URL (for active-link JS), and the
  site title. Called by Workbooks.Publish.Site for each page in a site build.
  """
  def site_page(title, body_html, nav_html, current_url, site_title) do
    """
    <!doctype html><html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>#{escape(title)} — #{escape(site_title)}</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@300;400;500;600;700&family=Geist+Mono:wght@400;500;600&display=swap">
    <style>
    :root{
      --ink:#232a36;--ink-soft:#3a4453;--ink-faint:#6b7585;
      --blue:#2f6fe0;--blue-soft:#5a8bea;--blue-faint:#e7eefc;
      --bg:#f4f6f9;--bg-warm:#eef1f6;--panel:#fff;
      --silver:#d6dbe3;--silver-light:#e9edf2;--line:#dfe4ec;
      --green:#1f9d6b;--amber:#d98b1f;
      --sans:"Geist",system-ui,-apple-system,sans-serif;
      --mono:"Geist Mono",ui-monospace,SFMono-Regular,Menlo,monospace;
      --sidebar-w:284px;
      --shadow:0 1px 2px rgba(35,42,54,.04),0 10px 28px rgba(35,42,54,.06);
      --shadow-lg:0 2px 6px rgba(35,42,54,.06),0 22px 56px rgba(35,42,54,.10);
    }
    *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
    html{-webkit-text-size-adjust:100%;scroll-behavior:smooth}
    body{background:var(--bg);color:var(--ink);font-family:var(--sans);font-weight:400;line-height:1.6;letter-spacing:-.006em;-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility;display:flex;min-height:100vh;position:relative}
    /* ── atmosphere: gradient wash + drifting blue glow + engineering dot grid ── */
    body::before{content:"";position:fixed;inset:0;z-index:-3;background:linear-gradient(180deg,#fff 0%,var(--bg) 55%,var(--bg-warm) 100%)}
    body::after{content:"";position:fixed;inset:0;z-index:-2;background:radial-gradient(58rem 58rem at 78% 10%,rgba(47,111,224,.07),transparent 60%),radial-gradient(46rem 46rem at 8% 92%,rgba(90,139,234,.055),transparent 62%);animation:drift 28s ease-in-out infinite alternate}
    @keyframes drift{0%{transform:translate3d(0,0,0)}100%{transform:translate3d(-3%,2.4%,0)}}
    .grid{position:fixed;inset:0;z-index:-1;background-image:radial-gradient(circle at 1px 1px,rgba(35,42,54,.055) 1px,transparent 0);background-size:23px 23px;-webkit-mask-image:linear-gradient(180deg,transparent,#000 24%,#000 76%,transparent);mask-image:linear-gradient(180deg,transparent,#000 24%,#000 76%,transparent);pointer-events:none}
    ::selection{background:var(--blue-faint);color:var(--ink)}
    /* ── liquid-metal accent ── */
    .metal{height:3px;border-radius:3px;background:linear-gradient(90deg,#b3bbc8,#7c869a 28%,var(--blue) 50%,#7c869a 72%,#b3bbc8);background-size:220% 100%;animation:shimmer 7s linear infinite}
    @keyframes shimmer{to{background-position:-220% 0}}
    /* ── sidebar ── */
    .sidebar{width:var(--sidebar-w);flex-shrink:0;border-right:1px solid var(--line);display:flex;flex-direction:column;position:sticky;top:0;height:100vh;overflow-y:auto;background:rgba(255,255,255,.62);-webkit-backdrop-filter:saturate(1.4) blur(10px);backdrop-filter:saturate(1.4) blur(10px)}
    .sidebar-head{padding:1.5rem 1.4rem 1.1rem;display:flex;align-items:center;gap:.6rem}
    .brand-mark{width:23px;height:23px;border-radius:7px;background:linear-gradient(135deg,#f3f5f9,#c9d0db 46%,var(--blue));box-shadow:inset 0 1px 0 rgba(255,255,255,.75),inset 0 -1px 2px rgba(35,42,54,.12),0 2px 7px rgba(47,111,224,.22);flex-shrink:0}
    .sidebar-title{font-family:var(--mono);font-size:.86rem;font-weight:600;letter-spacing:.01em;color:var(--ink);text-decoration:none}
    .sidebar-close{display:none;background:none;border:none;color:var(--ink-faint);cursor:pointer;font-size:1rem;padding:.2rem;margin-left:auto}
    .nav-body{padding:.5rem .8rem 3rem;flex:1}
    .nav-label{font-family:var(--mono);font-size:.68rem;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:var(--ink-faint);padding:.9rem .55rem .4rem;margin-top:.4rem}
    .nav-body ul{list-style:none;margin-bottom:.3rem}
    .nav-body li a{display:block;font-size:.875rem;font-weight:400;color:var(--ink-soft);text-decoration:none;padding:.34rem .55rem;border-radius:7px;transition:color .15s,background .15s,box-shadow .15s;position:relative}
    .nav-body li a:hover{color:var(--ink);background:rgba(231,238,252,.5)}
    .nav-body li a.active,.nav-body li a[aria-current=page]{color:var(--blue);background:var(--blue-faint);font-weight:500;box-shadow:inset 2px 0 0 var(--blue)}
    /* ── main content ── */
    .page-wrap{flex:1;min-width:0;display:flex;flex-direction:column}
    .page-header{padding:3rem 3.2rem 1.6rem;position:relative}
    .page-header .metal{position:absolute;top:0;left:0;width:64px;margin:0}
    .page-eyebrow{font-family:var(--mono);font-size:.76rem;font-weight:500;letter-spacing:.06em;text-transform:uppercase;color:var(--blue);margin-bottom:.7rem}
    .page-title{font-size:clamp(1.8rem,4vw,2.6rem);font-weight:600;line-height:1.08;letter-spacing:-.03em;color:var(--ink)}
    .page-body{padding:2.2rem 3.2rem 6rem;max-width:792px}
    /* ── typography (body) ── */
    .page-body h2{font-size:1.32rem;font-weight:600;letter-spacing:-.02em;color:var(--ink);margin:clamp(2.6rem,5vh,3.2rem) 0 .8rem;padding-top:clamp(1.8rem,4vh,2.4rem);border-top:1px solid var(--line)}
    .page-body h2:first-child{margin-top:.4rem;padding-top:0;border-top:0}
    .page-body h3{font-family:var(--mono);font-size:.8rem;font-weight:600;letter-spacing:.03em;color:var(--ink-faint);text-transform:uppercase;margin:1.9rem 0 .55rem}
    .page-body p{max-width:66ch;font-size:1.02rem;margin-bottom:1rem;line-height:1.7;color:var(--ink-soft)}
    .page-body strong{color:var(--ink);font-weight:600}
    .page-body a{color:var(--blue);text-decoration:none;border-bottom:1px solid rgba(47,111,224,.28);transition:border-color .15s}
    .page-body a:hover{border-bottom-color:var(--blue)}
    .page-body code{font-family:var(--mono);font-size:.86em;background:var(--silver-light);color:var(--ink);border:1px solid var(--line);border-radius:5px;padding:.08em .4em}
    .page-body pre{background:var(--panel);border:1px solid var(--line);border-radius:13px;padding:1.15rem 1.35rem;overflow-x:auto;margin:1.4rem 0;box-shadow:var(--shadow);position:relative}
    .page-body pre::before{content:"";position:absolute;top:0;left:1.35rem;right:1.35rem;height:1px;background:linear-gradient(90deg,transparent,var(--silver),transparent)}
    .page-body pre code{font-size:.84rem;line-height:1.8;background:none;border:none;padding:0;color:var(--ink)}
    .page-body table{width:100%;border-collapse:separate;border-spacing:0;font-size:.92rem;margin:1.6rem 0;background:var(--panel);border:1px solid var(--line);border-radius:13px;overflow:hidden;box-shadow:var(--shadow)}
    .page-body th{font-family:var(--mono);font-size:.72rem;font-weight:600;letter-spacing:.04em;text-transform:uppercase;color:var(--ink-faint);text-align:left;padding:.7rem .9rem;background:var(--bg-warm);border-bottom:1px solid var(--line)}
    .page-body td{padding:.65rem .9rem;border-bottom:1px solid var(--silver-light);vertical-align:top;color:var(--ink-soft)}
    .page-body tr:last-child td{border-bottom:0}
    .page-body td code{font-size:.84em}
    .page-body ul,.page-body ol{padding-left:1.45rem;margin-bottom:1rem}
    .page-body li{font-size:1.02rem;line-height:1.7;margin-bottom:.3rem;color:var(--ink-soft)}
    .page-body li::marker{color:var(--blue-soft)}
    .page-body blockquote{border-left:3px solid var(--blue);padding:.2rem 0 .2rem 1.1rem;margin:1.2rem 0;color:var(--ink-faint);font-style:italic}
    /* ── mermaid diagrams ── */
    .mermaid{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:1.6rem 1.4rem;margin:1.7rem 0;box-shadow:var(--shadow-lg);text-align:center;overflow-x:auto}
    .mermaid:not([data-processed]){min-height:60px;color:transparent}
    /* ── page-load motion ── */
    @keyframes rise{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:none}}
    @media(prefers-reduced-motion:no-preference){
      .page-header{animation:rise .5s cubic-bezier(.2,.7,.2,1) both}
      .page-body{animation:rise .5s cubic-bezier(.2,.7,.2,1) .06s both}
    }
    /* ── mobile ── */
    .topbar{display:none;align-items:center;gap:.75rem;padding:.9rem 1.25rem;border-bottom:1px solid var(--line);background:rgba(255,255,255,.85);-webkit-backdrop-filter:blur(8px);backdrop-filter:blur(8px);position:sticky;top:0;z-index:10}
    .topbar .brand-mark{width:20px;height:20px}
    .topbar-title{font-family:var(--mono);font-size:.84rem;font-weight:600;color:var(--ink);text-decoration:none;flex:1}
    .menu-btn{background:var(--panel);border:1px solid var(--line);color:var(--ink-soft);cursor:pointer;font-size:.8rem;padding:.4rem .7rem;border-radius:8px;font-family:var(--mono);box-shadow:var(--shadow)}
    @media(max-width:860px){
      body{flex-direction:column}
      .topbar{display:flex}
      .sidebar{position:fixed;top:0;left:0;height:100vh;z-index:20;transform:translateX(-100%);transition:transform .25s ease;box-shadow:0 0 0 100vmax rgba(35,42,54,.32);background:rgba(255,255,255,.96)}
      .sidebar.open{transform:translateX(0)}
      .sidebar-close{display:block}
      .page-header{padding:2rem 1.4rem 1.2rem}
      .page-body{padding:1.6rem 1.4rem 4rem}
    }
    </style></head>
    <body>
    <div class="grid"></div>
    <div class="topbar">
      <button class="menu-btn" onclick="toggleSidebar()">☰</button>
      <a href="/index.html" class="topbar-title"><span class="brand-mark"></span> #{escape(site_title)}</a>
    </div>
    #{nav_html}
    <div class="page-wrap">
      <div class="page-header">
        <div class="metal"></div>
        <p class="page-eyebrow">#{escape(site_title)}</p>
        <h1 class="page-title">#{escape(title)}</h1>
      </div>
      <div class="page-body">
        #{body_html}
      </div>
    </div>
    <script>
    (function(){
      var url = #{Jason.encode!(current_url)};
      document.querySelectorAll('.nav-body a[data-url]').forEach(function(a){
        if(a.getAttribute('data-url')===url){a.classList.add('active');a.setAttribute('aria-current','page')}
      });
    })();
    function toggleSidebar(){document.getElementById('sidebar').classList.toggle('open');}
    document.addEventListener('keydown',function(e){if(e.key==='Escape')document.getElementById('sidebar').classList.remove('open')});
    </script>
    <script type="module">
    import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
    // promote fenced mermaid code blocks to live diagrams (by class or by content)
    document.querySelectorAll('pre code').forEach(function(c){
      var cls=(c.className||'')+' '+((c.parentElement&&c.parentElement.className)||'');
      var txt=c.textContent||'';
      if(/mermaid/i.test(cls) || /^\\s*(graph |flowchart |sequenceDiagram|stateDiagram|classDiagram|erDiagram|journey|gantt|pie |mindmap|timeline)/.test(txt)){
        var d=document.createElement('div');d.className='mermaid';d.textContent=txt;
        var pre=c.closest('pre'); if(pre) pre.replaceWith(d);
      }
    });
    mermaid.initialize({startOnLoad:false,theme:'base',securityLevel:'loose',fontFamily:'"Geist Mono",ui-monospace,monospace',themeVariables:{
      background:'#ffffff',primaryColor:'#e7eefc',primaryBorderColor:'#2f6fe0',primaryTextColor:'#232a36',
      secondaryColor:'#eef1f6',secondaryBorderColor:'#d6dbe3',secondaryTextColor:'#3a4453',
      tertiaryColor:'#ffffff',tertiaryBorderColor:'#dfe4ec',
      lineColor:'#6b7585',textColor:'#232a36',fontSize:'13px',
      nodeBorder:'#2f6fe0',mainBkg:'#e7eefc',clusterBkg:'#f4f6f9',clusterBorder:'#d6dbe3',
      edgeLabelBackground:'#ffffff',labelBoxBkgColor:'#ffffff'
    }});
    mermaid.run({querySelector:'.mermaid'});
    </script>
    </body></html>
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

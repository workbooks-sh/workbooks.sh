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

  # Public change feed (wb-5vm / lander-live): the app's git log, newest-first,
  # capped at 30. Anonymous GET — no auth, no writes. The underscore prefix avoids
  # any collision with workbook paths. Mirrors web.ex's /rcp/changes but resolves
  # the app from the public host rather than an authed tenant.
  get "/_changes" do
    case app_id(conn) do
      nil ->
        send_resp(conn, 404, "no app for host")

      app ->
        entries = Workbooks.Git.log_entries(app) |> Enum.take(30)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{changes: entries, agent: Workbooks.Keeper.status()}))
    end
  end

  # Live activity for follow-along (lander): keeper status + the tail of the
  # agent's step telemetry (_steps.jsonl in the tenant repo) + a cosmetic
  # narration line. Anonymous GET, read-only — same plane rules as /_changes.
  #
  # Two shapes (wb-wc0.2):
  #   * SINGLETON (no crew): the legacy `{agent, steps, thought}` shape — the
  #     lander frontend reads it unchanged.
  #   * CREW (WB_CREW_DEF set): a `{agents, wire, agent}` shape — per-agent status
  #     + thought, a merged `wire` of recent steps tagged by agent, AND a legacy
  #     `agent` block for the busiest/most-recent agent (backward-compat so the
  #     existing frontend still renders something without crew awareness).
  get "/_activity" do
    case app_id(conn) do
      nil ->
        send_resp(conn, 404, "no app for host")

      app ->
        body =
          if Workbooks.Keeper.Crew.active?(),
            do: crew_activity(app),
            else: singleton_activity(app)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))
    end
  end

  # Legacy single-agent shape — untouched behavior for the lander.
  defp singleton_activity(app) do
    status = Workbooks.Keeper.status()
    steps = activity_tail(app)

    %{
      agent: status,
      steps: steps,
      thought:
        Workbooks.Thoughts.current(steps, status[:running] == true) ||
          latest_daydream(app)
    }
  end

  # Crew shape: one entry per declared agent + a merged wire + a legacy `agent`
  # block for backward compat. All step telemetry comes from the SAME
  # _steps.jsonl, now tagged with each step's `agent` (wb-wc0.2 §3).
  defp crew_activity(app) do
    all = activity_tail(app, 60)
    contexts = Workbooks.Keeper.Crew.agent_contexts()

    agents =
      Enum.map(contexts, fn {name, suffix, lc_ctx} ->
        status = Workbooks.Keeper.Worker.status(suffix, lc_ctx)
        steps = Enum.filter(all, &(&1.agent == name)) |> Enum.take(-5)

        %{
          name: name,
          running: status[:running] == true,
          lifecycle: status[:lifecycle],
          steps: steps,
          thought: Workbooks.Thoughts.current(Enum.reverse(steps), status[:running] == true, name)
        }
      end)

    # The legacy `agent` block: the busiest agent (one that's running) else the
    # most recently active. Lets a crew-unaware frontend still show a single agent.
    busiest = Enum.find(agents, & &1.running) || List.first(agents) || %{}
    legacy_status = legacy_block(busiest, contexts)

    %{
      agents: agents,
      wire: Enum.take(all, -10),
      agent: legacy_status
    }
  end

  # Reconstruct the legacy keeper-status block for the chosen agent.
  defp legacy_block(%{name: name} = a, contexts) do
    case Enum.find(contexts, fn {n, _, _} -> n == name end) do
      {_, suffix, lc_ctx} -> Workbooks.Keeper.Worker.status(suffix, lc_ctx) |> Map.put(:thought, a[:thought])
      _ -> %{}
    end
  end

  defp legacy_block(_, _), do: %{}

  # The dreaming state's voice: when no live thought, the newest daydream.
  defp latest_daydream(app) do
    with {:ok, j} <- File.read(Path.join(site_dir(app), "rem/daydreams.json")),
         {:ok, %{"daydreams" => [%{"text" => t} | _]}} <- Jason.decode(j) do
      t
    else
      _ -> nil
    end
  end

  # Last `n` step events (default 8), slimmed to what the page needs (tool +
  # target + ts + agent). The `agent` tag (nil for the singleton) lets the crew
  # shape group the shared wire by agent (wb-wc0.2 §3).
  defp activity_tail(app, n \\ 8) do
    path = Path.join(Workbooks.Git.repo_path(app), "_steps.jsonl")

    case File.read(path) do
      {:ok, data} ->
        data
        |> String.split("\n", trim: true)
        |> Enum.take(-n)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, ev} ->
              args = ev["args"] || %{}

              target =
                args["path"] || args["cmd"] || args["pipeline"] || args["query"] ||
                  args["url"] || ""

              [%{tool: ev["tool"], ts: ev["ts"], agent: ev["agent"], target: String.slice(to_string(target), 0, 120)}]

            _ ->
              []
          end
        end)

      _ ->
        []
    end
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

  # Serve a file from the host's published static site dir (build/public/<app>/).
  # Pages are PAGES, not files: clean URLs resolve extensionlessly
  # (`/learn/workbook` → learn/workbook.html), directories default to their
  # index, and inbound `.html` URLs 301 to the clean form so the suffix
  # retires everywhere. Path-traversal safe: ".." segments are rejected AND
  # the resolved path is contained within the site dir.
  defp serve_static(conn, dir) do
    with {:ok, rel} <- safe_rel(conn.request_path),
         path when path != nil <- resolve(Path.join(dir, rel)),
         true <- contained?(dir, path) do
      cond do
        # an explicit .html request for an existing page → canonical clean URL
        String.ends_with?(rel, ".html") and File.regular?(path) ->
          redirect(conn, clean_url(conn))

        String.starts_with?(MIME.from_path(path), "text/html") ->
          serve_html(conn, inject_marker(File.read!(path)))

        true ->
          conn |> put_resp_content_type(MIME.from_path(path)) |> send_file(200, path)
      end
    else
      _ -> send_resp(conn, 404, "not found")
    end
  end

  # try-files: exact match → `<path>.html` (the clean-URL page) → dir index.
  defp resolve(path) do
    cond do
      File.regular?(path) -> path
      File.regular?(path <> ".html") -> path <> ".html"
      File.dir?(path) and File.regular?(Path.join(path, "index.html")) -> Path.join(path, "index.html")
      true -> nil
    end
  end

  defp clean_url(conn) do
    base =
      case String.replace_suffix(conn.request_path, ".html", "") do
        p when p in ["/index", "index"] -> "/"
        p -> String.replace_suffix(p, "/index", "/")
      end

    case conn.query_string do
      "" -> base
      q -> base <> "?" <> q
    end
  end

  defp redirect(conn, to) do
    conn
    |> put_resp_header("location", to)
    |> send_resp(301, "moved: " <> to)
  end

  defp serve_html(conn, body),
    do: conn |> put_resp_content_type("text/html") |> csp() |> send_resp(200, inject_marker(body))

  # CSP on served Workbooks: a self-contained `.html` hydrates an in-page VFS from
  # its embedded `wb-bundle` zip. Those entries are DATA, not scripts — the runtime
  # treats hydrated HTML/JS/.wasm as inert until it EXPLICITLY evaluates them. The
  # header is a defense-in-depth floor so a hostile bundle's embedded markup can't
  # auto-execute with the serving origin's privileges (cookies / same-origin fetch /
  # control-plane session). `'unsafe-inline'` covers the page's own inline styles +
  # the wb-bundle-loader; `object-src 'none'`/`base-uri 'self'` close the obvious
  # injection vectors. The `wb-bundle` block itself is `type=application/zip`
  # (non-executable by type) — CSP is the belt to that suspenders.
  defp csp(conn) do
    policy =
      "default-src 'self'; " <>
        "script-src 'self' 'unsafe-inline'; " <>
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; " <>
        "font-src 'self' https://fonts.gstatic.com; " <>
        "img-src 'self' data: blob:; " <>
        "connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'"

    put_resp_header(conn, "content-security-policy", policy)
  end

  # Published static trees live under the durable data dir (WB_DATA → the volume)
  # so they survive machine restarts / scale-to-zero; fall back to cwd in dev.
  defp site_dir(app), do: Path.join([System.get_env("WB_DATA") || File.cwd!(), "build", "public", app])

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
    # A workbook may already BE a complete HTML document (the "one file" form:
    # built single-file workbooks, hand-authored pages). Serve those verbatim —
    # wrapping them in the doc shell below would double-nest <html> and bury the
    # author's own <head>/title. Only org-source content gets the kernel render
    # + shell treatment.
    if complete_html?(org) do
      org
    else
      static_doc(id, Workbooks.OQL.render(org))
    end
  end

  # True when the stored content opens as a full HTML document.
  defp complete_html?(content) do
    content
    |> String.trim_leading()
    |> String.downcase()
    |> String.starts_with?(["<!doctype html", "<html"])
  end

  @doc false
  def static_doc(id, rendered) do
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
    </main>
    #{Workbooks.Bundle.loader_block()}
    </body></html>
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
    <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Cdefs%3E%3ClinearGradient id='g' x1='0' y1='0' x2='1' y2='1'%3E%3Cstop offset='0' stop-color='%23f3f5f9'/%3E%3Cstop offset='.46' stop-color='%23c9d0db'/%3E%3Cstop offset='1' stop-color='%232f6fe0'/%3E%3C/linearGradient%3E%3C/defs%3E%3Crect width='32' height='32' rx='9' fill='url(%23g)'/%3E%3C/svg%3E">
    <title>#{escape(title)} — #{escape(site_title)}</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600;700&display=swap">
    <style>
    @font-face{font-family:"Franie";src:url("https://workbooks.sh/fonts/Franie-Light.woff2") format("woff2");font-weight:300;font-style:normal;font-display:block}
    @font-face{font-family:"Franie";src:url("https://workbooks.sh/fonts/Franie-SemiBold.woff2") format("woff2");font-weight:600;font-style:normal;font-display:block}
    @font-face{font-family:"Franie";src:url("https://workbooks.sh/fonts/Franie-SemiBoldItalic.woff2") format("woff2");font-weight:600;font-style:italic;font-display:block}
    @font-face{font-family:"Franie";src:url("https://workbooks.sh/fonts/Franie-Bold.woff2") format("woff2");font-weight:700;font-style:normal;font-display:block}
    @font-face{font-family:"Franie";src:url("https://workbooks.sh/fonts/Franie-BoldItalic.woff2") format("woff2");font-weight:700;font-style:italic;font-display:block}
    @font-face{font-family:"Franie";src:url("https://workbooks.sh/fonts/Franie-Black.woff2") format("woff2");font-weight:900;font-style:normal;font-display:block}
    :root{
      --ink:#121316;--ink-soft:#34372f;--ink-faint:#6a6f68;
      --blue:#149157;--blue-soft:#3fe081;--blue-faint:#e3f6ea;
      --bg:#f7f6f1;--bg-warm:#f1f0e8;--panel:#fff;
      --silver:#d9d6c8;--silver-light:#eceadf;--line:#e7e5db;
      --green:#13d943;--amber:#d98b1f;
      /* match the landing page: mono body, Franie display — sans/mono, no serif */
      --sans:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,monospace;
      --display:"Franie",sans-serif;
      --mono:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,monospace;
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
    /* DNA-seam divider — flat brand color blocks (matches the landing page seam) */
    .metal{height:1px;background:var(--line)}
    /* ── sidebar ── */
    .sidebar{width:var(--sidebar-w);flex-shrink:0;border-right:1px solid var(--line);display:flex;flex-direction:column;position:sticky;top:0;height:100vh;overflow-y:auto;background:rgba(255,255,255,.62);-webkit-backdrop-filter:saturate(1.4) blur(10px);backdrop-filter:saturate(1.4) blur(10px)}
    /* DNA strip — top of the left panel, full width, brand pastels; segments keep
       the same height and slowly fluctuate WIDTH against each other on a loop */
    .dnastrip{display:flex;width:100%;height:8px;overflow:hidden;flex:0 0 auto}
    .dnastrip i{height:100%;flex:1 1 0;min-width:2px;animation:dnaw 9s ease-in-out infinite}
    @keyframes dnaw{0%,100%{flex-grow:1}50%{flex-grow:3.4}}
    @media(prefers-reduced-motion:reduce){.dnastrip i{animation:none}}
    .sidebar-head{padding:1.5rem 1.4rem 1.1rem;display:flex;align-items:center;gap:.6rem}
    /* mono petal mark — no color; flips ink↔paper with the theme via the mask */
    .brand-mark{width:24px;height:24px;background:var(--ink);flex:0 0 auto;
      -webkit-mask:url("https://workbooks.sh/petal.svg") center/contain no-repeat;
      mask:url("https://workbooks.sh/petal.svg") center/contain no-repeat}
    .sidebar-sub{color:var(--ink-faint);font-weight:400;font-family:var(--mono);font-size:.86rem}
    .sidebar-sub-link{text-decoration:none;transition:color .15s}
    .sidebar-sub-link:hover{color:var(--blue)}
    .sidebar-title{font-family:var(--mono);font-size:.86rem;font-weight:600;letter-spacing:.01em;color:var(--ink);text-decoration:none}
    .sidebar-close{display:none;background:none;border:none;color:var(--ink-faint);cursor:pointer;font-size:1rem;padding:.2rem;margin-left:auto}
    .nav-body{padding:.5rem .8rem 3rem;flex:1}
    .nav-label{font-family:var(--mono);font-size:.68rem;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:var(--ink-faint);padding:.9rem .55rem .4rem .8rem;margin-top:.4rem;display:flex;align-items:center;gap:.5rem}
    .nav-label::before{content:"";flex:0 0 auto;width:7px;height:7px;border-radius:2px;background:var(--sx,var(--blue-soft))}
    .nav-body ul{list-style:none;margin-bottom:.3rem}
    .nav-body li a{display:block;font-size:.875rem;font-weight:400;color:var(--ink-soft);text-decoration:none;padding:.34rem .55rem;border-radius:7px;transition:color .15s,background .15s,box-shadow .15s;position:relative}
    .nav-body li a:hover{color:var(--ink);background:rgba(231,238,252,.5)}
    .nav-body li a.active,.nav-body li a[aria-current=page]{color:var(--blue);background:var(--blue-faint);font-weight:500;box-shadow:inset 2px 0 0 var(--blue)}
    /* ── main content ── */
    .page-wrap{flex:1;min-width:0;display:flex;flex-direction:column}
    .page-header{padding:3rem 3.2rem 1.6rem;position:relative}
    .page-header .metal{position:absolute;top:0;left:0;width:168px;margin:0}
    /* DNA-seam section dividers (replaces the plain h2 top border) */
    .page-body h2{border-top:0!important;position:relative}
    .page-body h2::before{content:"";position:absolute;top:calc(-1*clamp(.9rem,2vh,1.2rem));left:0;width:100%;height:1px;background:var(--line)}
    .page-body h2:first-child::before{display:none}
    .page-eyebrow{font-family:var(--mono);font-size:.76rem;font-weight:500;letter-spacing:.06em;text-transform:uppercase;color:var(--blue);margin-bottom:.7rem}
    .page-title{font-family:var(--display);font-size:clamp(2rem,4.4vw,2.9rem);font-weight:600;line-height:1.05;letter-spacing:-.01em;color:var(--ink)}
    .page-title em,.page-body h2 em{font-style:italic;font-weight:600}
    /* cross-site links + copy-as-markdown button in the header */
    .page-cross{display:flex;align-items:center;gap:1.1rem;margin-bottom:1rem}
    .page-cross a{font-family:var(--mono);font-size:.72rem;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:var(--ink-faint);text-decoration:none}
    .page-cross a:hover{color:var(--blue)}
    .copy-md{margin-left:auto;display:inline-flex;align-items:center;gap:.45rem;font-family:var(--mono);font-size:.72rem;font-weight:600;letter-spacing:.04em;color:var(--ink);background:var(--panel);border:1.5px solid var(--ink);border-radius:8px;padding:.45rem .7rem;cursor:pointer;box-shadow:2px 2px 0 var(--ink);transition:transform .12s,box-shadow .12s}
    .copy-md:hover{transform:translate(-1px,-1px);box-shadow:3px 3px 0 var(--ink)}
    .copy-md:active{transform:translate(1px,1px);box-shadow:1px 1px 0 var(--ink)}
    .copy-md.done{background:var(--blue-faint);border-color:var(--blue);color:var(--blue)}
    .page-body{padding:2.2rem 3.2rem 6rem;max-width:792px}
    /* ── typography (body) ── */
    .page-body h2{font-family:var(--display);font-size:1.44rem;font-weight:600;letter-spacing:-.02em;color:var(--ink);margin:clamp(2.6rem,5vh,3.2rem) 0 .8rem;padding-top:clamp(1.8rem,4vh,2.4rem);border-top:1px solid var(--line)}
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
      <a href="/" class="topbar-title"><span class="brand-mark"></span> workbooks <span class="sidebar-sub">docs</span></a>
    </div>
    #{nav_html}
    <div class="page-wrap">
      <div class="page-header">
        <div class="metal"></div>
        <div class="page-cross">
          <a href="https://workbooks.sh/learn">Learn</a>
          <a href="https://workbooks.sh/blog">Blog</a>
          <a href="https://workbooks.sh/toolkits">Toolkits</a>
          <a href="https://github.com/workbooks-sh/workbooks.sh">GitHub</a>
          <button class="copy-md" id="copyMd" type="button" title="Copy this page as Markdown">⧉ Copy as Markdown</button>
        </div>
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
    // ── Copy as Markdown — convert the rendered page body to GFM, clipboard it ──
    (function(){
      var btn=document.getElementById('copyMd'); if(!btn) return;
      function md(el){
        var out=[];
        el.childNodes.forEach(function(n){
          if(n.nodeType===3){ var t=n.textContent.trim(); if(t) out.push(t); return; }
          if(n.nodeType!==1) return;
          var tag=n.tagName.toLowerCase(), tx=n.textContent.trim();
          if(tag==='h1') out.push('# '+tx);
          else if(tag==='h2') out.push('\\n## '+tx);
          else if(tag==='h3') out.push('\\n### '+tx);
          else if(tag==='h4') out.push('\\n#### '+tx);
          else if(tag==='p') out.push(inline(n));
          else if(tag==='pre') out.push('\\n```\\n'+tx+'\\n```');
          else if(tag==='ul') n.querySelectorAll(':scope>li').forEach(function(li){out.push('- '+inline(li))});
          else if(tag==='ol'){var i=1;n.querySelectorAll(':scope>li').forEach(function(li){out.push((i++)+'. '+inline(li))})}
          else if(tag==='blockquote') out.push('> '+tx);
          else if(tag==='table') out.push(table(n));
          else if(n.querySelector) out.push(md(n));
        });
        return out.filter(Boolean).join('\\n');
      }
      function inline(n){
        var s='';
        n.childNodes.forEach(function(c){
          if(c.nodeType===3) s+=c.textContent;
          else if(c.tagName){var t=c.tagName.toLowerCase(),x=c.textContent;
            if(t==='code') s+='`'+x+'`'; else if(t==='strong'||t==='b') s+='**'+x+'**';
            else if(t==='em'||t==='i') s+='*'+x+'*';
            else if(t==='a') s+='['+x+']('+(c.getAttribute('href')||'')+')'; else s+=x;}
        });
        return s.trim();
      }
      function table(t){
        var rows=[].slice.call(t.querySelectorAll('tr')), out=[];
        rows.forEach(function(r,i){
          var cells=[].slice.call(r.querySelectorAll('th,td')).map(function(c){return c.textContent.trim()});
          out.push('| '+cells.join(' | ')+' |');
          if(i===0) out.push('| '+cells.map(function(){return '---'}).join(' | ')+' |');
        });
        return '\\n'+out.join('\\n');
      }
      btn.addEventListener('click',function(){
        var body=document.querySelector('.page-body');
        var title=document.querySelector('.page-title');
        var text=(title?'# '+title.textContent.trim()+'\\n\\n':'')+md(body);
        navigator.clipboard.writeText(text).then(function(){
          btn.classList.add('done'); var o=btn.textContent; btn.textContent='✓ Copied';
          setTimeout(function(){btn.classList.remove('done');btn.textContent=o},1600);
        });
      });
    })();
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

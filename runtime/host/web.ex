defmodule Workbooks.Web do
  @moduledoc """
  The HTTP/WS surface. Authenticate, then create/resume Instances and run OQL.
  Bandit serves this Plug router (opt-in via WB_WEB=1).
  """
  use Plug.Router

  plug(Workbooks.Auth)
  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  # Parse Org through the OQL kernel.
  post "/oql/parse" do
    {:ok, body, conn} = read_body(conn)
    json = Jason.encode!(Workbooks.OQL.parse_headlines(body))
    conn |> put_resp_content_type("application/json") |> send_resp(200, json)
  end

  # List registered Instances for the tenant.
  get "/instances" do
    json = Jason.encode!(Workbooks.ControlPlane.list())
    conn |> put_resp_content_type("application/json") |> send_resp(200, json)
  end

  # Deploy a Workbook: store its Org source under :id.
  put "/w/:id" do
    {:ok, org, conn} = read_body(conn)
    Workbooks.deploy(conn.params["id"], org, conn.assigns.tenant)
    send_resp(conn, 201, "stored")
  end

  # Serve a Workbook as a webpage — the runtime renders the stored Org (or a
  # built-in sample if none is deployed under :id) and serves the UI.
  get "/w/:id" do
    id = conn.params["id"]
    org = Workbooks.ControlPlane.get_workbook(id) || sample_workbook()
    page = workbook_page(id, Workbooks.OQL.render(org))
    conn |> put_resp_content_type("text/html") |> send_resp(200, page)
  end

  # The Workbook's backend: the served page calls home to its own runtime.
  post "/w/:id/call" do
    {:ok, body, conn} = read_body(conn)
    %{"fn" => fun, "org" => org} = Jason.decode!(body)

    result =
      case fun do
        "parse" -> Workbooks.OQL.parse_headlines(org)
        "tangle" -> Workbooks.OQL.tangle_plan(org)
        "validate" -> Workbooks.OQL.validate(org)
        _ -> %{"error" => "unknown fn"}
      end

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
  end

  # Live bridge: upgrade to a WebSocket connected to this Workbook.
  get "/w/:id/ws" do
    conn
    |> WebSockAdapter.upgrade(Workbooks.Socket, %{id: conn.params["id"]}, timeout: 60_000)
    |> halt()
  end

  # Start a long-horizon agent run (returns immediately; poll /api/run/:id).
  # The same endpoint runs locally and in the deployed engine (Fly).
  post "/api/run" do
    {:ok, body, conn} = read_body(conn)
    %{"system" => system, "task" => task} = params = Jason.decode!(body)
    id = "run-#{System.unique_integer([:positive])}"

    opts =
      [tenant: conn.assigns.tenant, max_steps: params["max_steps"] || 40]
      |> then(&if params["model"], do: [{:model, params["model"]} | &1], else: &1)

    {:ok, _} = Workbooks.AgentSession.start(id, system, task, opts)
    json = Jason.encode!(%{id: id, status: "running"})
    conn |> put_resp_content_type("application/json") |> send_resp(202, json)
  end

  # Live agent telemetry — each tool step streamed as it happens (brandnana-style).
  get "/api/run/:id/stream" do
    conn
    |> WebSockAdapter.upgrade(Workbooks.AgentStream, %{id: conn.params["id"]}, timeout: 600_000)
    |> halt()
  end

  # Poll an agent run's status + result + observable events.org.
  get "/api/run/:id" do
    reply =
      case Workbooks.AgentSession.status(conn.params["id"]) do
        :not_found -> %{error: "no such run"}
        s -> s
      end

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(reply))
  end

  # Run the full brandnana brand book for a domain (harvest → strategist →
  # designer), the real pipeline ported onto the clean-room agent loop. Long-
  # horizon: spawns + returns immediately; poll /api/brand-book/:slug.
  post "/api/run-brand-book" do
    {:ok, body, conn} = read_body(conn)
    %{"domain" => domain} = Jason.decode!(body)
    slug = String.replace(domain, ~r/[^a-z0-9]/i, "-")
    workdir = "/tmp/bb/#{slug}"
    # FRESH per run: a reused workdir keeps the prior run's catalog SQLite, which
    # makes the re-crawl 409 ("already exists") → 0 products → a thin substrate
    # the strategist can't ground on. Each brand-book run starts from a clean dir.
    File.rm_rf!(workdir)
    File.mkdir_p!(workdir)
    # Capture any crash so a dead spawn is diagnosable (else status freezes silently).
    spawn(fn ->
      try do
        Workbooks.BrandBook.run(domain, workdir: workdir)
      rescue
        e -> File.write(Path.join(workdir, "_error.json"),
               Jason.encode!(%{error: Exception.message(e), kind: inspect(e.__struct__), trace: Exception.format_stacktrace(__STACKTRACE__) |> String.slice(0, 1200)}))
      end
    end)
    json = Jason.encode!(%{slug: slug, domain: domain, workdir: workdir, status: "running"})
    conn |> put_resp_content_type("application/json") |> send_resp(202, json)
  end

  # Poll a brand-book run — the stage + published deck URL (BrandBook writes
  # _status.json into the workdir as each stage starts/finishes).
  get "/api/brand-book/:slug" do
    path = "/tmp/bb/#{conn.params["slug"]}/_status.json"
    body = case File.read(path) do
      {:ok, j} -> j
      _ -> Jason.encode!(%{error: "no such run", slug: conn.params["slug"]})
    end
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  # Browse — the runtime's web capability, reachable over HTTP so any consumer
  # (brandnana harvest, an agent, an external caller) can fetch/crawl/search
  # through the configured provider (free native browser by default).
  #   {"url": "...", "mode": "fetch"|"crawl", "as": "org"|"json"}
  #   {"query": "...", "mode": "search"}
  post "/api/browse" do
    {:ok, body, conn} = read_body(conn)

    try do
      result = browse(Jason.decode!(body))
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
    rescue
      e ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{error: Exception.message(e)}))
    end
  end

  # The document viewer — a clean, Google-Docs-style reader for Workbooks.
  get "/docs" do
    conn |> put_resp_content_type("text/html") |> send_resp(200, viewer_page())
  end

  get "/api/workbooks" do
    json = Jason.encode!(Workbooks.ControlPlane.list_workbooks())
    conn |> put_resp_content_type("application/json") |> send_resp(200, json)
  end

  get "/api/w/:id/org" do
    org = Workbooks.ControlPlane.get_workbook(conn.params["id"]) || ""
    conn |> put_resp_content_type("text/plain; charset=utf-8") |> send_resp(200, org)
  end

  # Server-rendered HTML — the runtime renders the Org (orgize, in the kernel).
  get "/api/w/:id/html" do
    org = Workbooks.ControlPlane.get_workbook(conn.params["id"]) || ""
    conn |> put_resp_content_type("text/html; charset=utf-8") |> send_resp(200, Workbooks.OQL.render(org))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # The viewer SPA: the runtime renders Org→HTML server-side (orgize, in the
  # kernel); the page only fetches that HTML + colors code (highlight.js, BSD).
  # No client Org library, no chrome — a clean page.
  # Dispatch a /api/browse request to the Browse capability.
  defp browse(%{"mode" => "search", "query" => q} = p) do
    case Workbooks.Browse.search(q, limit: Map.get(p, "limit", 8)) do
      {:ok, results} -> %{mode: "search", query: q, results: results}
      {:error, reason} -> %{mode: "search", error: inspect(reason)}
    end
  end

  defp browse(%{"mode" => "crawl", "url" => url} = p) do
    {:ok, pages} = Workbooks.Browse.crawl(url, max_pages: Map.get(p, "max_pages", 10))
    render_pages(pages, Map.get(p, "as", "json"))
  end

  defp browse(%{"url" => url} = p) do
    case Workbooks.Browse.fetch(url) do
      {:ok, page} -> render_pages([page], Map.get(p, "as", "json"))
      {:error, reason} -> %{error: inspect(reason)}
    end
  end

  defp render_pages(pages, "org"),
    do: %{count: length(pages), org: Workbooks.Browse.Crawl.to_org(pages)}

  defp render_pages(pages, _),
    do: %{count: length(pages), pages: Enum.map(pages, &Map.take(&1, [:url, :title, :description, :headings]))}

  defp viewer_page do
    ~S"""
    <!doctype html><html lang="en"><head>
    <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Workbooks</title>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/highlight.js@11/styles/github.min.css">
    <style>
    *{box-sizing:border-box} html,body{margin:0;height:100%}
    body{font:16px/1.7 -apple-system,system-ui,"Segoe UI",Roboto,sans-serif;color:#202124;background:#f1f3f4;display:flex}
    #tabs{width:264px;height:100vh;overflow:auto;border-right:1px solid #e3e6e8;background:#fff;padding:1.1rem .6rem;flex:0 0 auto}
    #tabs h2{font-size:.66rem;text-transform:uppercase;letter-spacing:.09em;color:#80868b;padding:0 .6rem;margin:.2rem 0 .7rem}
    #tabs a{display:block;padding:.45rem .65rem;border-radius:8px;color:#3c4043;text-decoration:none;font-size:.9rem;cursor:pointer}
    #tabs a:hover{background:#f1f3f4} #tabs a.active{background:#e8f0fe;color:#1a73e8;font-weight:500}
    body>main{flex:1;height:100vh;overflow:auto;display:flex;justify-content:center;padding:3.5rem 1.5rem 6rem}
    #doc{background:#fff;max-width:740px;width:100%;padding:4.5rem 5.5rem;box-shadow:0 1px 3px rgba(60,64,67,.1);border-radius:2px;height:max-content}
    /* orgize wraps content in main/section — normalize them to plain blocks */
    #doc main,#doc section{display:block} #doc p:empty{display:none}
    #doc h1{font-size:1.9rem;font-weight:600;margin:0 0 1rem;letter-spacing:-.01em}
    #doc h2{font-size:1.4rem;font-weight:600;margin:2.2rem 0 .6rem}
    #doc h3{font-size:1.12rem;font-weight:600;margin:1.6rem 0 .4rem}
    #doc p{margin:.85rem 0} #doc a{color:#1a73e8}
    #doc :not(pre)>code,#doc code.inline-code{background:#f1f3f4;padding:.12em .38em;border-radius:5px;font-size:.86em;font-family:"SF Mono",Menlo,Consolas,monospace}
    #doc pre{background:#f8f9fa;border:1px solid #e8eaed;border-radius:10px;padding:1rem 1.25rem;overflow:auto;font-size:.85rem;line-height:1.55}
    #doc table{border-collapse:collapse;width:100%;margin:1.1rem 0;font-size:.93rem}
    #doc th,#doc td{border:1px solid #e8eaed;padding:.5rem .85rem;text-align:left} #doc th{background:#f8f9fa;font-weight:600}
    #doc blockquote{border-left:3px solid #dadce0;margin:1rem 0;padding:.2rem 0 .2rem 1.1rem;color:#5f6368}
    #doc .tag{display:inline-block;background:#e8eaed;color:#5f6368;border-radius:5px;padding:.08em .45em;font-size:.6em;vertical-align:middle;margin-left:.4em;text-transform:lowercase}
    #doc .kw{font-size:.62em;font-weight:700;padding:.18em .5em;border-radius:5px;margin-right:.5em;vertical-align:middle;letter-spacing:.04em}
    #doc .kw-TODO{background:#fce8e6;color:#c5221f} #doc .kw-DONE{background:#e6f4ea;color:#137333}
    #doc .kw-NEXT,#doc .kw-WAIT{background:#feefc3;color:#b06000}
    .empty{color:#80868b}
    </style></head>
    <body>
    <aside id="tabs"><h2>Documents</h2></aside>
    <main><article id="doc"></article></main>
    <script type="module">
    // The runtime renders Org→HTML (orgize, in the kernel). The page only fetches
    // the rendered HTML + colors code (highlight.js, BSD). No client Org library.
    import hljs from "https://esm.sh/highlight.js@11";
    const tabs = document.getElementById("tabs"), docEl = document.getElementById("doc");
    function sanitize(){
      docEl.querySelectorAll("h1,h2,h3,h4").forEach(h=>{
        const first = h.firstChild;
        if(first && first.nodeType===3){
          const m = first.textContent.match(/^\s*(TODO|DONE|NEXT|WAIT|ABANDONED)\b\s*/i);
          if(m){ first.textContent = first.textContent.slice(m[0].length);
            const b=document.createElement("span"); b.className="kw kw-"+m[1].toUpperCase(); b.textContent=m[1].toUpperCase();
            h.insertBefore(b, h.firstChild); }
        }
        h.childNodes.forEach(n=>{ if(n.nodeType===3){ let t=n.textContent.replace(/\s+/g," ").replace(/\s+$/,""); const L=t.replace(/[^A-Za-z]/g,"");
          n.textContent = (L && L===L.toUpperCase()) ? t.toLowerCase().replace(/\b\w/g,c=>c.toUpperCase()) : t; }});
      });
    }
    async function show(id, el){
      document.querySelectorAll("#tabs a").forEach(a=>a.classList.remove("active"));
      if(el) el.classList.add("active");
      docEl.innerHTML = await fetch("/api/w/"+id+"/html").then(r=>r.text());
      docEl.querySelectorAll("pre code").forEach(b=>hljs.highlightElement(b));
      sanitize();
    }
    const list = await fetch("/api/workbooks").then(r=>r.json());
    if(!list.length) docEl.innerHTML = "<p class='empty'>No workbooks yet — PUT one to /w/&lt;id&gt;.</p>";
    list.forEach((id,i)=>{ const a=document.createElement("a"); a.textContent=id; a.onclick=()=>show(id,a);
      tabs.appendChild(a); if(i===0) show(id,a); });
    </script>
    </body></html>
    """
  end

  # A built-in sample until Workbooks are loaded from the VFS / a Bundle.
  defp sample_workbook do
    """
    * Hello, Workbook                                 :workflow:
      SCHEDULED: <2026-06-06 Sat 09:00 +1d>
    ** Greet                                          :component:
       #+begin_src js :out greeting:string
       export default () => "hello from a workbook instance";
       #+end_src
    """
  end

  defp workbook_page(id, rendered) do
    """
    <!doctype html><html><head><meta charset="utf-8"><title>Workbook #{id}</title>
    <style>body{font:15px/1.6 system-ui,sans-serif;max-width:720px;margin:2rem auto;padding:0 1rem;color:#222}
    .tags{color:#aaa;font-weight:400;font-size:.7em}.schedule{color:#0a7}
    .iface{display:grid;grid-template-columns:max-content 1fr;gap:0 .6rem;font-size:.82em;color:#666;margin:.3rem 0}
    pre{background:#f6f7f9;padding:.6rem .8rem;border-radius:6px;overflow:auto}</style></head>
    <body><main id="workbook">#{rendered}</main>
    <script>
      // The Workbook UI talks to its backend — this same runtime. fetch for
      // one-shot calls, a WebSocket for live interaction.
      const ws = new WebSocket((location.protocol === "https:" ? "wss:" : "ws:") + "//" + location.host + "/w/#{id}/ws");
      window.wb = {
        call: (fn, org) => fetch("/w/#{id}/call", {method:"POST",
          headers:{"content-type":"application/json"}, body: JSON.stringify({fn, org})}).then(r => r.json()),
        live: (fn, org) => new Promise(res => { ws.onmessage = e => res(JSON.parse(e.data)); ws.send(JSON.stringify({fn, org})); })
      };
    </script></body></html>
    """
  end
end

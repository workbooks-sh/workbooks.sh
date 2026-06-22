defmodule Nexus.SSR do
  @moduledoc """
  The BEAM runtime's **server-side render** of a workbook (a folder of `.work`
  files) → one HTML string, with live per-tenant data from `Nexus.Store`. This is
  the request-time tier the served nexus (`Nexus.Server`) calls per request.

  NOT the canonical build-time weave: that is the Zig **reactor** (`work weave`),
  which runs natively and inside the wasm sandbox. This module is the runtime SSR
  mirror only — same render shape, live data — and is slated to fold onto the Zig
  weave once it can be invoked from the runtime.

  Render-aware: resources in the folder are compiled, and `show <Resource>`
  becomes a table of that resource's rows (columns from `__fields__`, every cell
  XSS-escaped, graceful empty-state).
  """

  # Cap rendered/baked rows so a huge resource can't blow the page to tens of MB; the full set
  # lives behind the server/local backend via nexus.data.
  @max_rows 500

  @doc """
  Weave a workbook folder into one self-contained HTML string.

  Options:
    * `:live` (default false) — data posture baked into `nexus.data`. false (local): baked rows are
      authoritative, the file works offline. true (server): the client prefers fresh `/data/:resource`.
    * `:tenant` (default `"default"`) — which tenant's rows to render/bake (data is partitioned).
    * `:bake` (default true) — inline the data islands. **Set false for a SHARED multi-tenant SSR
      shell** so one tenant's data never lands in a cache served to another; the client fetches its
      own tenant-scoped `/data` instead.
  """
  def render(root, opts \\ []) do
    pages = root |> files() |> Enum.map(fn p -> {Path.relative_to(p, root), Nexus.Literate.parse(File.read!(p))} end)
    ctx = %{tenant: Keyword.get(opts, :tenant, Nexus.Store.default_tenant()), bake: Keyword.get(opts, :bake, true)}

    # An `index` whose `app` block lists `section … page …` is a MULTI-PAGE workbook: render it as a
    # navigable site (a nav + a history router that swaps pages without reload). Pure mechanism — the
    # look comes entirely from the workbook's own `design` block, nothing is baked in here.
    case app_node(pages) do
      nil -> compose(pages, resources(pages), Keyword.get(opts, :live, false), ctx)
      app -> compose_site(root, pages, app, ctx)
    end
  end

  defp app_node(pages) do
    Enum.find_value(pages, fn {_f, nodes} ->
      Enum.find(nodes, &(&1.type == :code and &1.kind == "app"))
    end)
  end

  # ── multi-page site: an `app` block (sections → pages) → nav + history router ──────────────────
  # Unopinionated plumbing. Emits semantic, neutral structure (.wb-side / .wb-nav / .wb-page) with a
  # bare default skin so it's legible unstyled; ALL look (logo, colours, type) comes from the
  # workbook's own `design` block, injected verbatim. No brand, no theme, no per-app-name special-case.
  defp compose_site(root, pages, app, ctx) do
    meta = parse_app(app.ast)
    ctx = Map.put(ctx, :app, false)

    loaded =
      for s <- meta.sections, key <- s.pages, into: %{} do
        nodes =
          case File.read(Path.join(root, key <> ".work")) do
            {:ok, c} -> Nexus.Literate.parse(c)
            _ -> []
          end

        {key, {page_title(nodes), Enum.map_join(nodes, "\n", &render_node(&1, %{}, ctx))}}
      end

    nav =
      Enum.map_join(meta.sections, "\n", fn s ->
        links =
          Enum.map_join(s.pages, "", fn key ->
            {t, _} = Map.get(loaded, key, {key, ""})
            ~s(<a class="wb-link" data-route="#{esc(key)}" href="#{esc(key)}">#{esc(t)}</a>)
          end)

        ~s(<div class="wb-sec"><div class="wb-sec-title">#{esc(s.title)}</div>#{links}</div>)
      end)

    articles =
      Enum.map_join(meta.sections, "\n", fn s ->
        Enum.map_join(s.pages, "\n", fn key ->
          {_t, html} = Map.get(loaded, key, {key, ""})
          ~s(<article class="wb-page" data-route="#{esc(key)}" hidden><div class="prose">#{html}</div></article>)
        end)
      end)

    """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>#{esc(meta.title)}</title>
    <style>#{site_css()}</style>
    #{design_css(pages)}</head>
    <body>
    <div class="wb-site">
      <aside class="wb-side"><div class="wb-brand">#{esc(meta.title)}</div><nav class="wb-nav">#{nav}<i class="wb-active-mark" aria-hidden="true" hidden></i></nav></aside>
      <main class="wb-main">#{articles}</main>
    </div>
    <script>#{site_router()}</script>
    </body></html>
    """
  end

  # Parse the `app` block AST → %{title, sections: [%{title, pages: [route_key]}]}.
  defp parse_app(ast) do
    stmts = ast |> app_body() |> block_stmts()
    title = Enum.find_value(stmts, "", fn {:title, _, [t]} when is_binary(t) -> t; _ -> nil end)

    sections =
      Enum.flat_map(stmts, fn
        {:section, _, [t, [{:do, sb}]]} when is_binary(t) -> [%{title: t, pages: pages_of(sb)}]
        _ -> []
      end)

    %{title: title, sections: sections}
  end

  defp app_body({:app, _, args}) when is_list(args), do: Enum.find_value(args, fn [{:do, b}] -> b; _ -> nil end)
  defp app_body(_), do: nil
  defp block_stmts({:__block__, _, s}), do: s
  defp block_stmts(nil), do: []
  defp block_stmts(single), do: [single]
  defp pages_of(sb), do: block_stmts(sb) |> Enum.flat_map(fn {:page, _, [p]} when is_binary(p) -> [p]; _ -> [] end)

  # The workbook's own brand sheet(s), injected verbatim — the ONLY source of look for a site.
  defp design_css(pages) do
    for {_f, nodes} <- pages, n <- nodes, n.type == :code, n.kind == "design", into: "" do
      "<style>\n" <> n.body <> "\n</style>\n"
    end
  end

  # Bare neutral skin: enough to be legible with no design block; every rule is overridable.
  defp site_css do
    """
    *{box-sizing:border-box}
    body{margin:0;font:16px/1.6 system-ui,-apple-system,sans-serif;color:#1a1a1a;background:#fff}
    .wb-site{display:flex;align-items:flex-start;min-height:100vh;max-width:1180px;margin:0 auto}
    .wb-side{width:260px;flex:none;position:sticky;top:0;height:100vh;overflow-y:auto;padding:24px 18px}
    .wb-brand{font-weight:600;font-size:18px;margin-bottom:18px}
    .wb-sec{margin-bottom:16px}
    .wb-sec-title{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:#888;margin-bottom:6px}
    .wb-link{display:block;color:#333;text-decoration:none;padding:4px 8px;border-radius:6px;font-size:14.5px}
    .wb-link:hover{background:rgba(0,0,0,.05)}.wb-link.on{font-weight:600;background:rgba(0,0,0,.05)}
    .wb-main{flex:1;min-width:0;padding:48px 56px 120px;max-width:800px}
    .prose h1{font-size:30px;margin:0 0 .5em}.prose h2{font-size:21px;margin:1.6em 0 .4em}.prose h3{font-size:17px;margin:1.3em 0 .3em}
    .prose p{margin:.7em 0}.prose a{color:#0a6}.prose ul{padding-left:1.3em}
    .prose code{font-family:ui-monospace,monospace;font-size:.9em;background:rgba(0,0,0,.06);padding:.1em .35em;border-radius:4px}
    .prose pre{background:rgba(0,0,0,.05);padding:12px 14px;border-radius:8px;overflow-x:auto}.prose pre code{background:none;padding:0}
    .prose blockquote{border-left:3px solid #ccc;margin:1em 0;padding:.2em 1em;color:#555}
    .prose figure.unit{border:1px solid #e5e5e5;border-radius:10px;overflow:hidden;margin:1.2em 0}
    .prose figure.unit pre{margin:0;background:#fafafa;border-radius:0}
    @media(max-width:760px){.wb-side{display:none}.wb-main{padding:28px 18px}}
    """
  end

  # Base-aware history router: data-route keys are relative to the mount's <base href>, so the same
  # workbook works at `/` or mounted at `/<name>/`. Intercepts in-content `/path` links too.
  defp site_router do
    ~S"""
    (function(){
      // <base href> carries an asset-version segment (/_v/<ver>/) for cache-busting; strip it so the
      // router base is the clean mount path (users navigate clean URLs, no _v segment).
      var base=new URL(document.baseURI).pathname.replace(/_v\/[^/]+\/$/,'');
      function key(p){return p.indexOf(base)===0?p.slice(base.length):p.replace(/^\//,'');}
      function show(k){
        var arts=document.querySelectorAll('.wb-page'),hit=false;
        arts.forEach(function(a){var on=a.dataset.route===k;a.hidden=!on;if(on)hit=true;});
        if(!hit&&arts[0]){arts[0].hidden=false;k=arts[0].dataset.route;}
        document.querySelectorAll('.wb-link').forEach(function(l){l.classList.toggle('on',l.dataset.route===k);});
        mark();
        window.scrollTo(0,0);
      }
      // Neutral active-position indicator: expose the active link's geometry + accent on a
      // marker element. All appearance (visibility, colour, motion) is the brand sheet's call.
      function mark(){
        var act=document.querySelector('.wb-link.on'),mk=document.querySelector('.wb-active-mark');
        if(!act||!mk)return;
        var nv=act.closest('.wb-nav'),ar=act.getBoundingClientRect(),nr=nv.getBoundingClientRect();
        mk.style.top=(ar.top-nr.top)+'px';
        mk.style.height=ar.height+'px';
        var c=getComputedStyle(act).getPropertyValue('--sec');
        if(c)mk.style.setProperty('--wb-mark-color',c.trim());
        mk.hidden=false;
      }
      window.addEventListener('resize',mark);
      function go(k){history.pushState({},'',base+k);show(k);}
      document.addEventListener('click',function(e){
        var a=e.target.closest('a[data-route],a[href^="/"]');if(!a)return;
        var k=a.dataset.route||key(a.getAttribute('href'));
        if(document.querySelector('.wb-page[data-route="'+(window.CSS&&CSS.escape?CSS.escape(k):k)+'"]')){e.preventDefault();go(k);}
      });
      window.addEventListener('popstate',function(){show(key(location.pathname));});
      show(key(location.pathname));
    })();
    """
  end

  @doc false
  def page_title(nodes) do
    Enum.find_value(nodes, "", fn
      %{type: :heading, text: t} -> t
      _ -> nil
    end)
  end

  # SEO/social head tags. <title> already carries the title; here we add the meta description + Open
  # Graph tags so a workbook's homepage previews well in search + social. Generic mechanism — the title
  # is the leading file's first heading, the description its first prose paragraph (the natural place a
  # workbook states what it is). Both emit only when present; nothing brand-specific is baked in.
  defp seo_meta(title, desc) do
    og_title = ~s(<meta property="og:title" content="#{esc(title)}"><meta property="og:type" content="website">)

    if desc == "" do
      og_title
    else
      og_title <>
        ~s(<meta name="description" content="#{esc(desc)}"><meta property="og:description" content="#{esc(desc)}">)
    end
  end

  # The leading file's first real prose paragraph, stripped of light markdown + collapsed to one line,
  # capped at 160 chars (search-snippet length). "" when there's no prose.
  defp description(pages) do
    Enum.find_value(pages, "", fn {_f, nodes} ->
      Enum.find_value(nodes, fn
        %{type: :prose, text: t} -> (d = clean_desc(t)) != "" && d || nil
        _ -> nil
      end)
    end)
  end

  defp clean_desc(t) do
    s =
      t
      |> String.replace(~r/[*_`#>\[\]]/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    # ≤160 (search-snippet length); when longer, cut on a WORD boundary so it never ends mid-word.
    if String.length(s) <= 160, do: s, else: s |> String.slice(0, 160) |> String.replace(~r/\s+\S*$/, "")
  end

  # index.work is the composition root — it leads; the rest follow alphabetically.
  @doc """
  A tenant's resource data as `name => [row maps]` — the payload the served `/data/:resource` API
  returns and the baked islands inline. One extraction, shared by weave and the server, scoped by tenant.
  """
  def data(root, tenant \\ Nexus.Store.default_tenant()) do
    pages = root |> files() |> Enum.map(fn p -> {Path.relative_to(p, root), Nexus.Literate.parse(File.read!(p))} end)

    for {name, {:resource, mod}} when not is_nil(mod) <- resources(pages), into: %{} do
      {name, mod |> Nexus.Store.all(tenant) |> Enum.take(@max_rows) |> Enum.map(&row_to_map/1)}
    end
  end

  @doc """
  The `.work` files that belong to the surface rooted at `root`, in composition order
  (index.work first). Prunes nested surfaces (subdirs with their own index.work) and the
  TEMPLATE.work manifest. Shared with `Nexus.Resources` so tree-walking lives in one place.
  """
  def files(root) do
    # Nested surfaces (subdirs with their OWN index.work) are SEPARATE mounts — their .work files belong
    # to that surface, not this one. Prune those subtrees so a parent surface's weave stops at each child
    # surface's boundary (otherwise a home surface like `lander` swallows its `lander/blog` surface — its
    # title, its content, the lot). Latent until nested surfaces existed; exposed by the workspace reorg.
    nested =
      Path.wildcard(Path.join(root, "**/index.work"))
      |> Enum.map(&Path.dirname/1)
      |> Enum.reject(&(&1 == root))

    (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
    |> Enum.uniq()
    |> Enum.reject(fn p -> Enum.any?(nested, &String.starts_with?(p, &1 <> "/")) end)
    # TEMPLATE.work is the template manifest (metadata for the CLI / explorer), not app content.
    |> Enum.reject(&(Path.basename(&1) == "TEMPLATE.work"))
    |> Enum.sort_by(fn p -> {Path.basename(p) != "index.work", p} end)
  end

  # The page title is the first heading of the leading (index) file; default "workbook".
  defp title(pages) do
    Enum.find_value(pages, "workbook", fn {_f, nodes} ->
      Enum.find_value(nodes, fn
        %{type: :heading, text: t} -> t
        _ -> nil
      end)
    end)
  end

  # A nav linking each file's section — coherence for a multi-file workbook (skipped for one file).
  defp nav(pages) when length(pages) <= 1, do: ""

  defp nav(pages) do
    links =
      Enum.map_join(pages, "", fn {f, _nodes} ->
        ~s(<a href="##{anchor(f)}">#{esc(label(f))}</a>)
      end)

    ~s(<nav class="wb-nav">#{links}</nav>\n)
  end

  defp anchor(f), do: f |> String.replace(~r/[^A-Za-z0-9]+/, "-") |> String.trim("-")
  defp label(f), do: f |> Path.basename(".work") |> String.replace("-", " ")

  # name → render target. A `resource` → {:resource, struct module}; a wasm unit (rust/c/zig…) →
  # {:unit, node} so `show <Unit>` can compile + run it at build time and bake the output.
  defp resources(pages) do
    for {_f, nodes} <- pages, n <- nodes, n.type == :code, into: %{} do
      cond do
        n.kind == "resource" -> {n.name, {:resource, safe_compile(n)}}
        n.kind in ~w(rust c cpp zig) -> {n.name, {:unit, n}}
        true -> {n.name, nil}
      end
    end
  end

  defp safe_compile(node) do
    Nexus.Resource.compile(node)
  rescue
    _ -> nil
  end

  defp compose(pages, res, live, ctx) do
    # A workbook with a `client` island is an APP: the island IS the page, so the literate prose +
    # headings + source figures are CONTEXT, not rendered — only components (the island + `show`
    # data directives) emit. A workbook with no island renders as a document (prose + show + units),
    # the literate-publishing posture. To render markdown in an app, author it inside a component.
    app? = Enum.any?(pages, fn {_f, nodes} -> Enum.any?(nodes, &(&1.type == :code and &1.kind == "client")) end)
    ctx = Map.put(ctx, :app, app?)
    body = Enum.map_join(pages, "\n", &page(&1, res, ctx))

    """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>#{esc(title(pages))}</title>
    #{seo_meta(title(pages), description(pages))}
    <style>#{css(app?)}</style>
    #{design_css(pages)}</head>
    <body>
    #{if app?, do: "", else: nav(pages)}#{body}
    #{data_islands(res, ctx)}<script>#{js_shim(live)}</script>
    </body></html>
    """
  end

  # The BAKED data backend: each resource's (tenant-scoped) Store rows inlined as a JSON island the
  # browser reads. `bake: false` (multi-tenant shared SSR) inlines NOTHING — the client fetches its
  # own tenant-scoped /data, so a shared/cached shell never carries one tenant's data to another.
  defp data_islands(_res, %{bake: false}), do: ""

  defp data_islands(res, %{tenant: tenant}) do
    for {name, {:resource, mod}} when not is_nil(mod) <- res, into: "" do
      rows = mod |> Nexus.Store.all(tenant) |> Enum.take(@max_rows) |> Enum.map(&row_to_map/1)
      # html_safe escapes `<`/`>`/`&` so a `</script>` in data can't break out of the island (XSS).
      ~s(<script type="application/nexus-data" data-resource="#{esc(name)}">#{Jason.encode!(rows, escape: :html_safe)}</script>\n)
    end
  end

  defp row_to_map(struct) do
    struct |> Map.from_struct() |> Map.new(fn {k, v} -> {k, jsonable(v)} end)
  end

  # enum atoms → strings for the JSON payload (bool/nil stay native).
  defp jsonable(v) when is_atom(v) and v not in [true, false, nil], do: to_string(v)
  defp jsonable(v), do: v

  # window.nexus.data — the browser mirror of Nexus.Store, one API over three backends:
  #   * BAKED   — read the inlined JSON islands (local, static, zero-runtime)
  #   * LOCAL   — a mutable IndexedDB store (local-only + mutable: create() persists across reloads)
  #   * SERVER  — fetch('/data/<Resource>') (cloud/shared) — only when there is no local data at all
  # all() = baked ∪ local; create() writes local. Same API the served nexus exposes.
  defp js_shim(live) do
    """
    window.nexus = window.nexus || {};
    nexus.data = {
      _live: #{if(live, do: "true", else: "false")},
      _baked: null,
      _db: null,
      _loadBaked() {
        if (this._baked) return this._baked;
        this._baked = {};
        document.querySelectorAll('script[type="application/nexus-data"]').forEach(s => {
          this._baked[s.dataset.resource] = JSON.parse(s.textContent || '[]');
        });
        return this._baked;
      },
      _open() {
        if (this._db) return this._db;
        this._db = new Promise((res, rej) => {
          const r = indexedDB.open('nexus', 1);
          r.onupgradeneeded = e => {
            const db = e.target.result;
            if (!db.objectStoreNames.contains('rows')) db.createObjectStore('rows', { autoIncrement: true });
          };
          r.onsuccess = e => res(e.target.result);
          r.onerror = e => rej(e.target.error);
        });
        return this._db;
      },
      async _local(resource) {
        const db = await this._open();
        return new Promise(res => {
          const req = db.transaction('rows', 'readonly').objectStore('rows').getAll();
          req.onsuccess = () => res((req.result || []).filter(r => r.__resource === resource).map(({ __resource, ...row }) => row));
          req.onerror = () => res([]);
        });
      },
      async all(resource) {
        // server mode: prefer fresh /data (cached HTML stays current); fall back to baked/local.
        if (this._live) {
          try { const r = await fetch('data/' + encodeURIComponent(resource)); if (r.ok) return await r.json(); } catch (_) {}
        }
        const baked = this._loadBaked()[resource] || [];
        const local = await this._local(resource);
        if (baked.length || local.length) return baked.concat(local);
        try { const r = await fetch('data/' + encodeURIComponent(resource)); return r.ok ? await r.json() : []; }
        catch (_) { return []; }
      },
      async create(resource, row) {
        const db = await this._open();
        return new Promise((res, rej) => {
          const tx = db.transaction('rows', 'readwrite');
          tx.objectStore('rows').add(Object.assign({ __resource: resource }, row));
          tx.oncomplete = () => res(row);
          tx.onerror = () => rej(tx.error);
        });
      }
    };
    """
  end

  defp page({name, nodes}, res, ctx) do
    # In app mode (an island is present) only components render — the island and `show` data
    # directives; prose/headings/source figures are literate context. Same rule for one file or many.
    nodes = if ctx[:app], do: Enum.filter(nodes, &app_component?/1), else: nodes

    ~s(<section class="file" id="#{anchor(name)}" data-file="#{esc(name)}">\n) <>
      Enum.map_join(nodes, "\n", &render_node(&1, res, ctx)) <> "\n</section>"
  end

  # The only nodes that render into an app: the `client` island, the `design` brand sheet, and
  # `show <Resource|Unit>` directives.
  defp app_component?(%{type: :code, kind: "client"}), do: true
  defp app_component?(%{type: :code, kind: "design"}), do: true
  defp app_component?(%{type: :decl, text: "show " <> _}), do: true
  defp app_component?(_), do: false

  defp render_node(%{type: :heading, level: l, text: t}, _res, _ctx), do: "  <h#{l}>#{inline(t)}</h#{l}>"

  defp render_node(%{type: :prose, text: t}, _res, _ctx), do: block_md(t)

  # `show <Resource>` → a live data table; `show <Unit>` → the unit's `render()` output, baked.
  defp render_node(%{type: :decl, text: "show " <> rest}, res, ctx) do
    name = rest |> String.split() |> List.first()

    case Map.get(res, name) do
      {:resource, mod} -> render_show(name, mod, ctx)
      {:unit, node} -> render_unit(name, node, ctx)
      _ -> render_show(name, nil, ctx)
    end
  end

  defp render_node(%{type: :decl, text: t}, _res, _ctx), do: ~s(  <pre class="decl">#{esc(t)}</pre>)

  # A `client` block IS the browser island — its body (HTML/CSS/JS) is emitted verbatim into the
  # page so it runs client-side (the documented client lane). `server`/`resource`/etc. are machinery
  # that runs on the nexus, not shown in the rendered app.
  defp render_node(%{type: :code, kind: "client", body: b}, _res, _ctx), do: b

  # A `design` block is the brand sheet — a living design document. Its CSS is hoisted into <head>
  # by compose/compose_site (via design_css/1) so it loads BEFORE the body paints — emitting it here
  # in body order would flash unstyled content (FOUC). So in-body it renders nothing.
  defp render_node(%{type: :code, kind: "design"}, _res, _ctx), do: ""

  # Any other unit (server / sandbox / data / def / agent / resource …) renders as a labelled
  # source figure — the literate document shows its own code. Matches the canonical reactor weave.
  defp render_node(%{type: :code, kind: k, lang: l, name: nm, header: h, body: b}, _res, _ctx) do
    lang = if l in [nil, ""], do: "", else: ~s( <span class="lang">#{esc(l)}</span>)
    name = if nm in [nil, ""], do: "", else: ~s( <span class="nm">:#{esc(nm)}</span>)

    ~s(  <figure class="unit" data-unit="#{esc(k)}:#{esc(nm)}"><figcaption><span class="kind">#{esc(k)}</span>#{lang}#{name}</figcaption><pre><code>#{esc(h)} do\n#{esc(b)}\nend</code></pre></figure>)
  end

  defp render_node(_, _res, _ctx), do: ""

  # Minimal block markdown: blank-line-delimited paragraphs (soft-wrapped lines joined), `- ` lists,
  # `> ` blockquotes, and ``` fenced code. Inline formatting (bold/italic/code/links) applied per line.
  defp block_md(text) do
    text |> String.split("\n") |> group_blocks([]) |> Enum.reverse() |> Enum.map_join("\n", &render_block/1)
  end

  defp group_blocks([], acc), do: acc

  defp group_blocks(["```" <> _ | rest], acc) do
    {code, rest2} = Enum.split_while(rest, &(&1 != "```"))
    rest3 = case rest2 do ["```" | r] -> r; r -> r end
    group_blocks(rest3, [{:code, code} | acc])
  end

  defp group_blocks([line | rest], acc) do
    cond do
      String.trim(line) == "" ->
        group_blocks(rest, acc)

      String.starts_with?(line, ">") ->
        {q, rest2} = Enum.split_while([line | rest], &String.starts_with?(&1, ">"))
        group_blocks(rest2, [{:quote, q} | acc])

      String.starts_with?(line, "- ") ->
        # a list runs to the next blank line; soft-wrapped continuation lines (not
        # starting with "- ") fold into the current item rather than splitting off.
        {block, rest2} = Enum.split_while([line | rest], &(String.trim(&1) != ""))
        group_blocks(rest2, [{:ul, list_items(block)} | acc])

      String.starts_with?(String.trim(line), "|") ->
        {rows, rest2} = Enum.split_while([line | rest], &String.starts_with?(String.trim(&1), "|"))
        group_blocks(rest2, [{:table, rows} | acc])

      true ->
        {para, rest2} =
          Enum.split_while([line | rest], fn l ->
            tl = String.trim(l)
            tl != "" and not String.starts_with?(tl, "- ") and not String.starts_with?(tl, ">") and
              not String.starts_with?(tl, "|") and not String.starts_with?(l, "```")
          end)

        group_blocks(rest2, [{:p, para} | acc])
    end
  end

  defp render_block({:code, lines}), do: "  <pre><code>" <> esc(Enum.join(lines, "\n")) <> "</code></pre>"

  defp render_block({:quote, lines}) do
    body = lines |> Enum.map_join(" ", &(&1 |> String.replace(~r/^>\s?/, "") |> String.trim()))
    "  <blockquote>#{inline(body)}</blockquote>"
  end

  defp render_block({:ul, items}),
    do: "  <ul>" <> Enum.map_join(items, "", &"<li>#{inline(&1)}</li>") <> "</ul>"

  defp render_block({:p, lines}),
    do: "  <p>#{inline(lines |> Enum.map_join(" ", &String.trim/1))}</p>"

  # GFM-style pipe table: first row is the header, an optional `|---|---|` separator row
  # is dropped, the rest are body rows. Cells get inline formatting.
  defp render_block({:table, rows}) do
    cells = fn r -> r |> String.trim() |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1) end
    sep? = fn r -> String.contains?(r, "-") and Enum.all?(cells.(r), &Regex.match?(~r/^:?-{2,}:?$/, &1)) end
    rows = rows |> Enum.reject(&(String.trim(&1) == ""))

    {head, body} =
      case rows do
        [h | t] -> {cells.(h), t |> Enum.reject(sep?) |> Enum.map(cells)}
        [] -> {[], []}
      end

    th = "<thead><tr>" <> Enum.map_join(head, "", &"<th>#{inline(&1)}</th>") <> "</tr></thead>"
    tb = "<tbody>" <> Enum.map_join(body, "", fn r -> "<tr>" <> Enum.map_join(r, "", &"<td>#{inline(&1)}</td>") <> "</tr>" end) <> "</tbody>"
    "  <table class=\"data wb-verbs\">#{th}#{tb}</table>"
  end

  # Fold a list block into item strings: each "- " starts an item; any following
  # non-"- " line is a soft-wrapped continuation of the current item.
  defp list_items(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      case line do
        "- " <> item -> [String.trim(item) | acc]
        cont when acc == [] -> [String.trim(cont)]
        cont -> [hd(acc) <> " " <> String.trim(cont) | tl(acc)]
      end
    end)
    |> Enum.reverse()
  end

  # Compile the unit and run it — dispatching on the lane's execution shape. An ungranted host cap is
  # refused BEFORE running it (the weave is where the audit is enforced).
  #   {:wasm, _}    — a typed COMPONENT: instantiate + call its no-arg `render` export (rust/c/zig/swift).
  #   {:command, _} — a WASI COMMAND module (js/ts/python): run it, its STDOUT is the output.
  #   {:client, js} — browser JS (svelte/solid/client): emitted as a client island, run in the browser.
  defp render_unit(name, node, ctx) do
    case Nexus.Audit.unit(node) do
      [] -> render_artifact(name, Nexus.Compile.unit(node), Nexus.Capabilities.grants(node), ctx.tenant)
      ungranted ->
        ~s(  <div class="data-missing">#{esc(name)} blocked: ungranted caps #{esc(Enum.join(ungranted, ", "))}</div>)
    end
  end

  defp render_artifact(name, {:wasm, {:ok, comp}}, grants, tenant) do
    # Hold a render slot for the duration: the in-process component lane is now bounded + tenant-fair
    # (wb-whvy) so a burst of renders can't fan out past the memory wall or let one tenant starve others.
    Nexus.Wasm.Gate.with_slot(:render, tenant, fn ->
      with {:ok, p} <- Nexus.Sandbox.start(comp, grants, tenant),
           {:ok, val} <- Nexus.Sandbox.call(p, "render", []) do
        if Process.alive?(p), do: Process.exit(p, :normal)
        ~s(  <div class="unit-output" data-unit="#{esc(name)}">#{esc(val)}</div>)
      else
        _ -> ~s(  <div class="data-missing">#{esc(name)}.render unavailable</div>)
      end
    end)
  end

  defp render_artifact(name, {:command, {:ok, spec}}, _grants, _tenant) do
    case Nexus.Sandbox.run_command(spec, "") do
      {:ok, out} -> ~s(  <div class="unit-output" data-unit="#{esc(name)}">#{esc(String.trim(out))}</div>)
      _ -> ~s(  <div class="data-missing">#{esc(name)} command run failed</div>)
    end
  end

  defp render_artifact(name, {:client, js}, _grants, _tenant) do
    ~s(  <div class="unit-island" data-unit="#{esc(name)}"><script type="module">#{js}</script></div>)
  end

  defp render_artifact(name, _, _grants, _tenant), do: ~s(  <div class="data-missing">#{esc(name)} unavailable</div>)

  defp render_show(name, nil, _ctx),
    do: ~s(  <div class="data-missing">unknown resource <code>#{esc(name)}</code></div>)

  defp render_show(name, mod, ctx) do
    fields = Enum.map(mod.__fields__(), &elem(&1, 0))
    # `bake: false` = the SHARED multi-tenant SSR shell. It must inline NO tenant rows — not in the
    # JSON island AND not in the visible <table> — or a shell cached for tenant A leaks A's (or the
    # default tenant's) rows to tenant B. The client hydrates the table from its own scoped /data.
    all = if Map.get(ctx, :bake, true), do: Nexus.Store.all(mod, ctx.tenant), else: []
    total = length(all)
    rows = Enum.take(all, @max_rows)
    header = Enum.map_join(fields, "", &"<th>#{esc(&1)}</th>")

    caption =
      if total > @max_rows,
        do: ~s(#{esc(name)} <span class="cap">— showing #{@max_rows} of #{total}; full set via nexus.data</span>),
        else: esc(name)

    body =
      if rows == [] do
        ~s(<tr><td colspan="#{max(length(fields), 1)}" class="empty">no rows yet</td></tr>)
      else
        Enum.map_join(rows, "", fn row ->
          "<tr>" <> Enum.map_join(fields, "", fn f -> "<td>#{esc(Map.get(row, f))}</td>" end) <> "</tr>"
        end)
      end

    ~s(  <table class="data" data-resource="#{esc(name)}"><caption>#{caption}</caption><thead><tr>#{header}</tr></thead><tbody>#{body}</tbody></table>)
  end

  # Minimal inline markdown: **bold**, *italic*, `code`, [text](url). Escape first, then format.
  defp inline(t) do
    t
    |> esc()
    |> String.replace(~r/\*\*(.+?)\*\*/, "<strong>\\1</strong>")
    |> String.replace(~r/(?<!\*)\*(?!\*)(.+?)\*(?!\*)/, "<em>\\1</em>")
    |> String.replace(~r/`(.+?)`/, "<code>\\1</code>")
    |> String.replace(~r/\[(.+?)\]\(([^\s)]+)\)/, ~s(<a href="\\2">\\1</a>))
  end

  # XSS-safe escape for every interpolated value (text, data cells, attributes).
  defp esc(s) do
    s
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  # An app (client island) renders full-bleed — it owns its own layout via its `design` block. A
  # document (prose) keeps the legible reading column. Either way the design block overrides this skin.
  defp css(app? \\ false)
  defp css(true) do
    """
    body{margin:0;font:16px/1.6 system-ui,sans-serif;color:#1a1a1a}
    """ <> css_common()
  end

  defp css(false) do
    """
    body{max-width:46rem;margin:2rem auto;padding:0 1rem;font:16px/1.6 system-ui,sans-serif;color:#1a1a1a}
    """ <> css_common()
  end

  defp css_common do
    """
    h1,h2,h3{line-height:1.25;margin:1.6em 0 .5em} code{background:#f4f4f5;padding:.1em .3em;border-radius:3px;font-size:.9em}
    .unit{margin:1.2em 0;border:1px solid #e4e4e7;border-radius:8px;overflow:hidden}
    .unit figcaption{background:#fafafa;padding:.4em .8em;font-size:.85em;border-bottom:1px solid #e4e4e7}
    .unit .kind{display:inline-block;background:#1a1a1a;color:#fff;padding:.05em .5em;border-radius:4px;font-size:.8em;margin-right:.4em}
    .unit pre{margin:0;padding:.8em;overflow-x:auto;background:#fff} pre code{background:none}
    .decl{background:#f4f4f5;padding:.6em;border-radius:6px;font-size:.85em}
    table.data{border-collapse:collapse;width:100%;margin:1.2em 0;font-size:.92em}
    table.data caption{text-align:left;font-weight:600;margin-bottom:.3em}
    table.data th,table.data td{border:1px solid #e4e4e7;padding:.35em .6em;text-align:left}
    table.data thead th{background:#fafafa} table.data .empty{color:#999;font-style:italic}
    table.data caption .cap{font-weight:400;color:#999;font-size:.85em}
    .data-missing{color:#b00;font-size:.9em}
    .unit-output{margin:1em 0;padding:.6em .9em;background:#f0f7ff;border-left:3px solid #4a90d9;border-radius:4px}
    nav.wb-nav{display:flex;gap:.8em;flex-wrap:wrap;padding:.6em 0;margin-bottom:1em;border-bottom:1px solid #e4e4e7;font-size:.9em}
    nav.wb-nav a{color:#555;text-decoration:none} nav.wb-nav a:hover{color:#000}
    """
  end
end

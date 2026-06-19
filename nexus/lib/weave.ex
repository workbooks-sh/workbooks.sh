defmodule Nexus.Weave do
  @moduledoc """
  A workbook (a folder of `.work` files) → ONE self-contained `.html`. A workbook IS an HTML file:
  the browser renders it, no runtime required. Prose narrates; `show Resource` directives render
  live data tables from `Nexus.Store`; unit code embeds. The data layer is pluggable (baked /
  local SQLite / server) behind one API — see docs/WEAVE-PLAN.md.

  Render-aware: resources in the folder are compiled, and `show <Resource>` becomes a table of
  that resource's rows (columns from `__fields__`, every cell XSS-escaped, graceful empty-state).
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
  def weave(root, opts \\ []) do
    pages = root |> files() |> Enum.map(fn p -> {Path.relative_to(p, root), Nexus.Literate.parse(File.read!(p))} end)
    ctx = %{tenant: Keyword.get(opts, :tenant, Nexus.Store.default_tenant()), bake: Keyword.get(opts, :bake, true)}
    render(pages, resources(pages), Keyword.get(opts, :live, false), ctx)
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

  defp files(root) do
    (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
    |> Enum.uniq()
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

  defp render(pages, res, live, ctx) do
    # Bring up the workbook's live capabilities: register each `fleet` unit as a Nexus.Live source
    # (resolving its `agent:` to that agent unit's prompt) so a `view` template can subscribe to it.
    register_fleets(pages, collect_agents(pages))

    # An APP workbook (one that defines a `view`) renders as a full-screen app — just the view(s),
    # no document chrome. The prose/agent/fleet units are the app's source, not its rendered body.
    # A workbook with no view renders as a literate document (prose + data tables + unit output).
    case collect_views(pages) do
      [] -> document(pages, res, live, ctx)
      views -> app(views, title(pages))
    end
  end

  defp document(pages, res, live, ctx) do
    body = Enum.map_join(pages, "\n", &page(&1, res, ctx))

    """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><title>#{esc(title(pages))}</title>
    <style>#{css()}</style></head>
    <body>
    #{nav(pages)}#{body}
    #{data_islands(res, ctx)}<script>#{js_shim(live)}</script>
    </body></html>
    """
  end

  # Full-screen app: only the view(s) render, filling the viewport. No nav, no prose, no code figures.
  defp app(views, title) do
    body = Enum.map_join(views, "\n", fn {n, s, i} -> live_view_html(n, s, i) end)

    """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="darkreader-lock"><meta name="color-scheme" content="dark">
    <title>#{esc(title)}</title>
    <style>html,body{height:100%;margin:0;background:#0c0d10;overflow:hidden}</style></head>
    <body>
    #{body}
    </body></html>
    """
  end

  # the view units, as {name, stream, intro}.
  defp collect_views(pages) do
    for {_f, nodes} <- pages, %{type: :code, kind: "view", name: n, header: h, body: b} <- nodes do
      {n, opt(h, "stream") || n, b}
    end
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
          try { const r = await fetch('/data/' + encodeURIComponent(resource)); if (r.ok) return await r.json(); } catch (_) {}
        }
        const baked = this._loadBaked()[resource] || [];
        const local = await this._local(resource);
        if (baked.length || local.length) return baked.concat(local);
        try { const r = await fetch('/data/' + encodeURIComponent(resource)); return r.ok ? await r.json() : []; }
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
    ~s(<section class="file" id="#{anchor(name)}" data-file="#{esc(name)}">\n) <>
      Enum.map_join(nodes, "\n", &render_node(&1, res, ctx)) <> "\n</section>"
  end

  defp render_node(%{type: :heading, level: l, text: t}, _res, _ctx), do: "  <h#{l}>#{inline(t)}</h#{l}>"

  defp render_node(%{type: :prose, text: t}, _res, _ctx) do
    t
    |> String.split("\n")
    |> Enum.chunk_by(&String.starts_with?(&1, "- "))
    |> Enum.map_join("\n", fn
      ["- " <> _ | _] = items ->
        "  <ul>" <> Enum.map_join(items, "", fn "- " <> i -> "<li>#{inline(i)}</li>" end) <> "</ul>"

      paras ->
        paras |> Enum.reject(&(String.trim(&1) == "")) |> Enum.map_join("\n", &"  <p>#{inline(&1)}</p>")
    end)
  end

  # `show <Resource>` → a live data table; `show <Unit>` → the unit's `render()` output, baked.
  defp render_node(%{type: :decl, text: "show " <> rest}, res, ctx) do
    name = rest |> String.split() |> List.first()

    case Map.get(res, name) do
      {:resource, mod} -> render_show(name, mod, ctx)
      {:unit, node} -> render_unit(name, node)
      _ -> render_show(name, nil, ctx)
    end
  end

  defp render_node(%{type: :decl, text: t}, _res, _ctx), do: ~s(  <pre class="decl">#{esc(t)}</pre>)

  # A `fleet` unit is a live capability, registered in render/4 — it renders nothing on the page.
  defp render_node(%{type: :code, kind: "fleet"}, _res, _ctx), do: ""

  # A `view :name, stream: <fleet>` unit renders the live-fleet viewer bound to that stream — the
  # compose bar + the shrinking grid of agent windows. The body (if any) is shown as the intro.
  defp render_node(%{type: :code, kind: "view", name: n, header: h, body: b}, _res, _ctx) do
    live_view_html(n, opt(h, "stream") || n, b)
  end

  defp render_node(%{type: :code, kind: k, name: n, body: b}, _res, _ctx) do
    ~s(  <figure class="unit" data-unit="#{esc(k)}:#{esc(n)}">) <>
      ~s(<figcaption><span class="kind">#{esc(k)}</span> #{esc(n)}</figcaption>) <>
      ~s(<pre>#{esc(b)}</pre></figure>)
  end

  defp render_node(_, _res, _ctx), do: ""

  # ── live fleet capability (the `fleet` + `view` units) ────────────────────────────────────────
  # agent name → system prompt (its unit body), across all files.
  defp collect_agents(pages) do
    for {_f, nodes} <- pages, %{type: :code, kind: "agent", name: nm, body: bd} <- nodes, into: %{} do
      {nm, String.trim(bd || "")}
    end
  end

  # Register each `fleet :name, agent: <ref>` unit as a Nexus.Live source running Nexus.Fleet with
  # the referenced agent's prompt. The view's EventSource hits GET /live/<name>?q=&max=.
  defp register_fleets(pages, agents) do
    for {_f, nodes} <- pages, %{type: :code, kind: "fleet", name: nm, header: h} <- nodes do
      prompt = Map.get(agents, opt(h, "agent"))

      Nexus.Live.register(nm, fn params, emit ->
        q = params["q"] || ""
        max = parse_int(params["max"], 12)
        Nexus.Fleet.run(q, max: max, agent: prompt, on_event: emit)
      end)
    end

    :ok
  end

  # read `key: value` (a bareword/atom) from a unit header.
  defp opt(header, key) do
    case Regex.run(~r/\b#{key}:\s*:?([A-Za-z_]\w*)/, header) do
      [_, v] -> v
      _ -> nil
    end
  end

  defp parse_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> default
    end
  end

  defp parse_int(_, default), do: default

  # The live-fleet-viewer primitive: a compose bar (task + max agents) and a single-viewport grid of
  # agent windows that tile and shrink as the fleet grows, each rendering one real agent's live state
  # streamed from `GET /live/<stream>`. This is the reusable rendering of a `view` bound to a fleet —
  # not hand-rolled per demo.
  defp live_view_html(name, stream, intro) do
    ~s"""
      <div class="work-fleet" id="fleet-#{esc(name)}" data-stream="#{esc(stream)}">
        <header class="wf-bar">
          <span class="wf-brand">Nexus Fleet<small>one nexus · live agents</small></span>
          <form class="wf-form">
            <input class="wf-q" type="text" placeholder="Research a topic… e.g. BEAM concurrency" value="WebAssembly runtimes" autocomplete="off">
            <span class="wf-max">max agents <input class="wf-n" type="number" min="1" max="64" value="24"></span>
            <button class="wf-go" type="submit">Run fleet</button>
          </form>
          <span class="wf-stat"><b class="wf-live">0</b> live · <b class="wf-spawned">0</b> of <b class="wf-cap">0</b></span>
        </header>
        <main class="wf-grid"></main>
      </div>
      <style>
      .work-fleet{--bg:#0c0d10;--panel:#15171c;--line:#23262e;--ink:#e7e9ee;--dim:#8b909c;--accent:#7dd3a8;
        --searching:#4a90d9;--reading:#e0a042;--thinking:#a070e0;--done:#3fbf6f;
        position:fixed;inset:0;background:var(--bg);color:var(--ink);display:flex;flex-direction:column;
        font:14px/1.5 ui-sans-serif,system-ui,sans-serif}
      .work-fleet .wf-bar{flex:none;display:flex;gap:.8rem;align-items:center;padding:.55rem .8rem;border-bottom:1px solid var(--line);background:var(--panel)}
      .work-fleet .wf-brand{font-weight:650;white-space:nowrap}.work-fleet .wf-brand small{color:var(--dim);font-weight:400;margin-left:.4rem}
      .work-fleet .wf-form{display:flex;gap:.5rem;align-items:center;flex:1}
      .work-fleet input{background:#0e0f13;border:1px solid var(--line);color:var(--ink);border-radius:8px;padding:.5rem .7rem;outline:none}
      .work-fleet input:focus{border-color:var(--accent)}
      .work-fleet .wf-q{flex:1;min-width:10rem} .work-fleet .wf-n{width:4rem;text-align:right}
      .work-fleet .wf-max{color:var(--dim);font-size:.85em;display:flex;gap:.4rem;align-items:center;white-space:nowrap}
      .work-fleet .wf-go{background:var(--accent);color:#06281a;border:0;border-radius:8px;padding:.55rem 1rem;font-weight:650;cursor:pointer}
      .work-fleet .wf-go:disabled{opacity:.5}
      .work-fleet .wf-stat{flex:none;color:var(--dim);font-size:.8em;font-variant-numeric:tabular-nums;white-space:nowrap} .work-fleet .wf-stat b{color:var(--ink)}
      .work-fleet .wf-grid{flex:1;min-height:0;display:grid;gap:4px;padding:6px}
      .work-fleet .wf-tile{position:relative;background:var(--panel);border:1px solid var(--line);border-radius:6px;overflow:hidden;display:flex;flex-direction:column;min-width:0;min-height:0;animation:wfpop .25s ease-out}
      @keyframes wfpop{from{transform:scale(.6);opacity:0}to{transform:scale(1);opacity:1}}
      .work-fleet .wf-h{flex:none;height:14px;display:flex;align-items:center;gap:4px;padding:0 5px;background:#0e0f13;border-bottom:1px solid var(--line);font-size:9px;color:var(--dim)}
      .work-fleet .wf-dot{width:7px;height:7px;border-radius:50%;flex:none;background:var(--dim)}
      .work-fleet .wf-b{flex:1;min-height:0;padding:5px 6px;font-size:10px;line-height:1.3;overflow:hidden;display:-webkit-box;-webkit-line-clamp:5;-webkit-box-orient:vertical}
      .work-fleet .wf-u{color:var(--dim);font-size:9px;margin-top:3px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .work-fleet .wf-tile[data-s=searching] .wf-dot{background:var(--searching);box-shadow:0 0 6px var(--searching)}
      .work-fleet .wf-tile[data-s=reading] .wf-dot{background:var(--reading);box-shadow:0 0 6px var(--reading)}
      .work-fleet .wf-tile[data-s=thinking] .wf-dot{background:var(--thinking);box-shadow:0 0 6px var(--thinking)}
      .work-fleet .wf-tile[data-s=done] .wf-dot{background:var(--done)} .work-fleet .wf-tile[data-s=done]{opacity:.6}
      .work-fleet .wf-grid.tiny .wf-h,.work-fleet .wf-grid.tiny .wf-b{display:none}
      .work-fleet .wf-grid.tiny .wf-tile::after{content:"";position:absolute;inset:0;background:currentColor;opacity:.14}
      .work-fleet .wf-grid.tiny .wf-tile[data-s=searching]{color:var(--searching)} .work-fleet .wf-grid.tiny .wf-tile[data-s=reading]{color:var(--reading)}
      .work-fleet .wf-grid.tiny .wf-tile[data-s=thinking]{color:var(--thinking)} .work-fleet .wf-grid.tiny .wf-tile[data-s=done]{color:var(--done)}
      </style>
      <script>(function(){
        var root=document.getElementById('fleet-#{esc(name)}'); if(!root) return;
        var stream=root.dataset.stream, grid=root.querySelector('.wf-grid'), tiles={}, live=0, spawned=0, es=null;
        var q=root.querySelector('.wf-q'), n=root.querySelector('.wf-n'), go=root.querySelector('.wf-go');
        function st(){root.querySelector('.wf-live').textContent=live;root.querySelector('.wf-spawned').textContent=spawned;}
        function relayout(){var c=Object.keys(tiles).length||1;var r=grid.clientWidth/grid.clientHeight||1.6;
          var cols=Math.max(1,Math.ceil(Math.sqrt(c*r)));var rows=Math.ceil(c/cols);
          grid.style.gridTemplateColumns='repeat('+cols+',1fr)';grid.style.gridTemplateRows='repeat('+rows+',1fr)';
          grid.classList.toggle('tiny',(grid.clientWidth/cols)<86||(grid.clientHeight/rows)<54);}
        function ev(e){
          if(e.type==='fleet'){root.querySelector('.wf-cap').textContent=e.max;return;}
          if(e.type==='spawn'){var t=document.createElement('div');t.className='wf-tile';t.dataset.s='thinking';
            t.innerHTML='<div class="wf-h"><span class="wf-dot"></span><span>'+e.id+'</span></div><div class="wf-b"><span class="wf-a">'+(e.query||'')+'</span><div class="wf-u"></div></div>';
            grid.appendChild(t);tiles[e.id]=t;spawned++;live++;st();relayout();return;}
          if(e.type==='state'){var t=tiles[e.id];if(!t)return;t.dataset.s=e.status;
            var a=t.querySelector('.wf-a'),u=t.querySelector('.wf-u');if(a&&e.action)a.textContent=e.action;if(u)u.textContent=e.url||'';return;}
          if(e.type==='done'){var t=tiles[e.id];if(t){if(t.dataset.s!=='done')live--;t.dataset.s='done';var a=t.querySelector('.wf-a');if(a&&e.finding)a.textContent=e.finding;}st();return;}
          if(e.type==='fleet_done'||e.type==='end'){go.disabled=false;go.textContent='Run fleet';if(es){es.close();es=null;}}
        }
        root.querySelector('.wf-form').addEventListener('submit',function(x){x.preventDefault();
          if(es)es.close();grid.innerHTML='';tiles={};live=0;spawned=0;st();
          var query=encodeURIComponent((q.value||'').trim()||'WebAssembly');var max=Math.max(1,Math.min(64,parseInt(n.value)||24));
          go.disabled=true;go.textContent='Running…';
          es=new EventSource('/live/'+encodeURIComponent(stream)+'?q='+query+'&max='+max);
          es.onmessage=function(m){try{ev(JSON.parse(m.data));}catch(_){}};
          es.onerror=function(){go.disabled=false;go.textContent='Run fleet';};
        });
        addEventListener('resize',relayout);
      })();</script>
    """
  end

  # Compile the unit (any lane), run its no-arg `render` export on wasmex, bake the result.
  # An ungranted host cap is refused BEFORE running it (the weave is where the audit is enforced).
  defp render_unit(name, node) do
    case Nexus.Audit.unit(node) do
      [] ->
        with {:wasm, {:ok, comp}} <- Nexus.Compile.unit(node),
             {:ok, p} <- Nexus.Sandbox.start(comp, []),
             {:ok, val} <- Nexus.Sandbox.call(p, "render", []) do
          ~s(  <div class="unit-output" data-unit="#{esc(name)}">#{esc(val)}</div>)
        else
          _ -> ~s(  <div class="data-missing">#{esc(name)}.render unavailable</div>)
        end

      ungranted ->
        ~s(  <div class="data-missing">#{esc(name)} blocked: ungranted caps #{esc(Enum.join(ungranted, ", "))}</div>)
    end
  end

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
    |> String.replace(~r/\[(.+?)\]\((https?:\/\/[^\s)]+)\)/, ~s(<a href="\\2">\\1</a>))
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

  defp css do
    """
    body{max-width:46rem;margin:2rem auto;padding:0 1rem;font:16px/1.6 system-ui,sans-serif;color:#1a1a1a}
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

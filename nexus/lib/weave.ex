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
    <meta name="darkreader-lock"><meta name="color-scheme" content="light">
    <title>#{esc(title)}</title>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/gsap/3.12.5/gsap.min.js"></script>
    <style>html,body{height:100%;margin:0;background:#fafafa;overflow:hidden}</style></head>
    <body>
    #{body}
    </body></html>
    """
  end

  @doc "Register a workbook's live capabilities (its `fleet` units) without rendering — call at boot."
  def bringup(root) do
    pages = root |> files() |> Enum.map(fn p -> {Path.relative_to(p, root), Nexus.Literate.parse(File.read!(p))} end)
    register_fleets(pages, collect_agents(pages))
  rescue
    _ -> :ok
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
        result = Nexus.Fleet.run(q, max: max, agent: prompt, on_event: emit)

        # Persist the completed session to the workbook's SQLite history.
        Nexus.Sessions.save(%{
          query: q,
          agents: length(result.findings),
          report: result.report,
          findings: Enum.map(result.findings, &Map.take(&1, [:id, :subtask, :finding]))
        })
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

  # The live-fleet-viewer primitive — a research-assistant app: a centered "Search Swarm" launcher;
  # on submit, agents pop into an inspectable thread (each expandable to its live step timeline +
  # page previews); when the fleet drains, their findings are compiled into a final report at the top.
  # Streamed from `GET /live/<stream>`. The reusable rendering of a `view` bound to a fleet.
  defp live_view_html(name, stream, _intro) do
    ~s"""
      <div class="aiapp" id="app-#{esc(name)}" data-stream="#{esc(stream)}">
        <header class="bar">
          <span class="logo"><span class="glyph"></span> Search Swarm</span>
          <span class="bstat"></span>
          <button class="newbtn" type="button" hidden>New search</button>
        </header>
        <div class="split">
          <section class="orch">
            <div class="olog">
              <div class="welcome">
                <h1>What should the swarm research?</h1>
                <p class="sub">An orchestrator agent breaks your question down and dispatches a fleet of research agents — you watch them work on the right.</p>
                <div class="chips">
                  <button class="chip" type="button">How does BEAM concurrency work?</button>
                  <button class="chip" type="button">Compare WebAssembly runtimes</button>
                  <button class="chip" type="button">State of local-first sync engines</button>
                </div>
                <div class="recent"></div>
              </div>
            </div>
            <form class="composer">
              <textarea class="cin" rows="1" placeholder="Ask the swarm to research anything…"></textarea>
              <div class="cbar">
                <div class="stepper" title="number of agents">
                  <button class="sdec" type="button" aria-label="fewer">−</button>
                  <span class="snum">8</span><span class="slbl">agents</span>
                  <button class="sinc" type="button" aria-label="more">+</button>
                </div>
                <span class="grow"></span>
                <button class="send" type="submit" aria-label="Search">
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="none"><path d="M12 19V5M12 5l-6 6M12 5l6 6" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>
                </button>
              </div>
            </form>
          </section>
          <section class="board">
            <div class="bhead"><span class="btitle">Agent board</span><span class="bcount"></span></div>
            <div class="grid"></div>
            <aside class="detail" hidden></aside>
          </section>
        </div>
      </div>
      <style>
      .aiapp{--bg:#fafafa;--surface:#fff;--line:#e7e7ea;--line2:#ededf0;--ink:#18181b;--muted:#71717a;--subtle:#a1a1aa;
        --accent:#6366f1;--searching:#3b82f6;--reading:#f59e0b;--thinking:#8b5cf6;--done:#10b981;
        position:fixed;inset:0;background:var(--bg);color:var(--ink);display:flex;flex-direction:column;
        font:14.5px/1.6 ui-sans-serif,system-ui,-apple-system,"Inter",sans-serif;-webkit-font-smoothing:antialiased}
      .aiapp *{box-sizing:border-box}
      .aiapp .bar{flex:none;display:flex;align-items:center;gap:.7rem;padding:.65rem 1.1rem;background:#fafafacc;backdrop-filter:saturate(1.6) blur(8px);border-bottom:1px solid var(--line2);z-index:5}
      .aiapp .logo{display:flex;align-items:center;gap:.5rem;font-weight:600;letter-spacing:-.01em}
      .aiapp .glyph{width:16px;height:16px;border-radius:5px;background:conic-gradient(from 210deg,var(--accent),#a855f7,#22d3ee,var(--accent));box-shadow:0 0 0 1px #fff inset}
      .aiapp .bstat{flex:1;color:var(--subtle);font-size:.82em;font-variant-numeric:tabular-nums}
      .aiapp .newbtn{background:var(--surface);border:1px solid var(--line);color:var(--ink);border-radius:9px;padding:.4rem .8rem;font-size:.85em;cursor:pointer}
      .aiapp .newbtn:hover{background:#f4f4f5}
      .aiapp .split{flex:1;min-height:0;display:flex}
      .aiapp .orch{flex:none;width:min(42%,460px);display:flex;flex-direction:column;border-right:1px solid var(--line2);min-width:320px}
      .aiapp .olog{flex:1;min-height:0;overflow-y:auto;padding:1.1rem}
      .aiapp .welcome{padding:6vh .2rem 0}
      .aiapp .welcome h1{margin:0 0 .4rem;font-size:1.5rem;letter-spacing:-.02em;font-weight:640}
      .aiapp .welcome .sub{margin:0 0 1.3rem;color:var(--muted)}
      .aiapp .chips{display:flex;gap:.45rem;flex-wrap:wrap;margin-bottom:1.2rem}
      .aiapp .chip{background:var(--surface);border:1px solid var(--line);color:var(--muted);border-radius:999px;padding:.4rem .8rem;font-size:.82em;cursor:pointer;transition:.15s}
      .aiapp .chip:hover{color:var(--ink);border-color:var(--accent)}
      .aiapp .rh{color:var(--subtle);font-size:.72em;text-transform:uppercase;letter-spacing:.06em;margin:.4rem 0 .3rem}
      .aiapp .ritem{display:flex;gap:.6rem;align-items:baseline;padding:.5rem .1rem;border-top:1px solid var(--line2);cursor:pointer}
      .aiapp .ritem:hover .rq{color:var(--accent)}
      .aiapp .rq{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .aiapp .rmeta{flex:none;color:var(--subtle);font-size:.76em}
      .aiapp .omsg{margin-bottom:1rem;animation:none}
      .aiapp .omsg .who{display:flex;align-items:center;gap:.45rem;font-size:.74em;color:var(--subtle);margin-bottom:.3rem;text-transform:uppercase;letter-spacing:.04em}
      .aiapp .omsg .who .glyph{width:13px;height:13px}
      .aiapp .omsg.user .bubble{background:var(--accent);color:#fff;border-radius:13px 13px 4px 13px;padding:.55rem .8rem;display:inline-block;max-width:90%}
      .aiapp .omsg.orch .bubble{color:var(--ink)}
      .aiapp .omsg .bubble p{margin:.4rem 0}.aiapp .omsg .bubble h2{font-size:1rem;margin:.6rem 0 .3rem}.aiapp .omsg .bubble h3{font-size:.92rem;margin:.7rem 0 .2rem}
      .aiapp .omsg .bubble ul{margin:.4rem 0;padding-left:1.1rem}.aiapp .omsg .bubble a{color:var(--accent);text-decoration:none}.aiapp .omsg .bubble a:hover{text-decoration:underline}
      .aiapp .activity{font-size:.85em;color:var(--muted);border-left:2px solid var(--line);padding:.1rem .7rem;margin:.3rem 0 .8rem}
      .aiapp .activity .aln{padding:.1rem 0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .aiapp .shimmer{background:linear-gradient(90deg,#a1a1aa,#18181b,#a1a1aa);background-size:200% 100%;-webkit-background-clip:text;background-clip:text;color:transparent;animation:sh 1.6s linear infinite}
      @keyframes sh{to{background-position:-200% 0}}
      .aiapp .composer{flex:none;margin:.8rem;background:var(--surface);border:1px solid var(--line);border-radius:16px;padding:.6rem .6rem .5rem;box-shadow:0 2px 6px #0000000d,0 14px 40px -24px #00000026;transition:.15s}
      .aiapp .composer:focus-within{border-color:#c7c9ff;box-shadow:0 2px 6px #0000000d,0 14px 40px -20px #6366f140}
      .aiapp .cin{width:100%;border:0;outline:0;resize:none;background:none;color:var(--ink);font:inherit;font-size:.97rem;padding:.25rem .4rem;max-height:34vh}
      .aiapp .cin::placeholder{color:var(--subtle)}
      .aiapp .cbar{display:flex;align-items:center;gap:.5rem;margin-top:.3rem}
      .aiapp .stepper{display:flex;align-items:center;gap:.25rem;background:#f4f4f5;border:1px solid var(--line);border-radius:999px;padding:.12rem .3rem;color:var(--muted);font-size:.8em}
      .aiapp .stepper button{width:19px;height:19px;border:0;border-radius:50%;background:none;color:var(--muted);cursor:pointer;line-height:1}
      .aiapp .stepper button:hover{background:#e4e4e7;color:var(--ink)}
      .aiapp .snum{min-width:1.1em;text-align:center;color:var(--ink);font-weight:600}
      .aiapp .grow{flex:1}
      .aiapp .send{width:32px;height:32px;flex:none;border:0;border-radius:10px;background:var(--accent);color:#fff;display:grid;place-items:center;cursor:pointer}
      .aiapp .send:hover{filter:brightness(1.08)}.aiapp .send:disabled{background:#d4d4d8}
      .aiapp .board{flex:1;min-width:0;display:flex;flex-direction:column;position:relative;background:#f6f6f7}
      .aiapp .bhead{flex:none;display:flex;align-items:center;gap:.5rem;padding:.7rem 1rem;color:var(--muted);font-size:.85em}
      .aiapp .btitle{font-weight:600;color:var(--ink)}
      .aiapp .bcount{font-variant-numeric:tabular-nums}
      .aiapp .grid{flex:1;min-height:0;display:grid;gap:6px;padding:0 .8rem .8rem;align-content:start;grid-template-columns:repeat(auto-fill,minmax(74px,1fr))}
      .aiapp .tile{position:relative;background:var(--surface);border:1px solid var(--line);border-radius:12px;aspect-ratio:1;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:.25rem;cursor:pointer;overflow:hidden;transition:transform .12s,box-shadow .12s}
      .aiapp .tile:hover{transform:translateY(-1px);box-shadow:0 4px 14px -6px #00000026}
      .aiapp .tile .av{width:42%;border-radius:6px;overflow:hidden;display:block}
      .aiapp .tile .av svg{display:block;width:100%;height:auto}
      .aiapp .tile .tid{font-size:9px;color:var(--subtle);font-variant-numeric:tabular-nums}
      .aiapp .tile .ring{position:absolute;top:5px;right:5px;width:8px;height:8px;border-radius:50%;background:var(--subtle)}
      .aiapp .tile[data-s=searching] .ring{background:var(--searching)}.aiapp .tile[data-s=reading] .ring{background:var(--reading)}
      .aiapp .tile[data-s=thinking] .ring{background:var(--thinking)}.aiapp .tile[data-s=done] .ring{background:var(--done)}
      .aiapp .tile[data-s=searching] .ring,.aiapp .tile[data-s=reading] .ring,.aiapp .tile[data-s=thinking] .ring{animation:pulse 1.3s ease-in-out infinite}
      @keyframes pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.45;transform:scale(.8)}}
      .aiapp .grid.tiny{grid-template-columns:repeat(auto-fill,minmax(34px,1fr))}
      .aiapp .grid.tiny .tile{border-radius:8px}.aiapp .grid.tiny .tid{display:none}.aiapp .grid.tiny .tile .av{width:64%}
      .aiapp .grid.mini{grid-template-columns:repeat(auto-fill,minmax(20px,1fr));gap:3px}.aiapp .grid.mini .tile{border-radius:5px}.aiapp .grid.mini .tid{display:none}.aiapp .grid.mini .tile .av{width:80%}
      .aiapp .detail{position:absolute;top:0;right:0;bottom:0;width:min(380px,80%);background:var(--surface);border-left:1px solid var(--line);box-shadow:-12px 0 40px -24px #00000033;overflow-y:auto;padding:1rem 1.1rem}
      .aiapp .detail .dh{display:flex;align-items:center;gap:.6rem;margin-bottom:.5rem}
      .aiapp .detail .dh .av{width:30px;border-radius:7px;overflow:hidden}.aiapp .detail .dh .av svg{width:100%;display:block}
      .aiapp .detail .dx{margin-left:auto;border:0;background:none;color:var(--muted);cursor:pointer;font-size:1.2em}
      .aiapp .detail .dtask{color:var(--muted);font-size:.9em;margin-bottom:.7rem}
      .aiapp .detail .sec{font-size:.74em;text-transform:uppercase;letter-spacing:.05em;color:var(--subtle);margin:.9rem 0 .3rem}
      .aiapp .detail .step{display:flex;gap:.5rem;padding:.14rem 0;color:var(--muted);font-size:.86em}
      .aiapp .detail .step b{color:var(--ink);font-weight:500;flex:none;width:4.4rem;text-transform:capitalize}
      .aiapp .detail .src{display:block;padding:.4rem .55rem;margin:.3rem 0;border:1px solid var(--line2);border-radius:9px;background:#fcfcfd}
      .aiapp .detail .src .surl{font-size:.8em;color:var(--accent);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .aiapp .detail .src .sprev{font-size:.82em;color:var(--muted);margin-top:.3rem;max-height:7em;overflow:hidden;white-space:pre-wrap}
      .aiapp .detail .find{margin-top:.5rem;padding:.6rem .7rem;background:#f4f7f5;border-radius:9px;color:var(--ink)}
      </style>
      <script>(function(){
        var root=document.getElementById('app-#{esc(name)}'); if(!root) return;
        var G=window.gsap, stream=root.dataset.stream, es=null, agents={}, order=[], live=0, spawned=0, naAgents=8;
        var olog=root.querySelector('.olog'), grid=root.querySelector('.grid'), detail=root.querySelector('.detail');
        var bstat=root.querySelector('.bstat'), bcount=root.querySelector('.bcount'), newbtn=root.querySelector('.newbtn');
        var cin=root.querySelector('.cin'), snum=root.querySelector('.snum');
        function esc(s){return (s==null?'':String(s)).replace(/[&<>]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;'}[c];});}
        function md(t){return esc(t)
          .replace(/^### (.*)$/gm,'<h3>$1</h3>').replace(/^## (.*)$/gm,'<h3>$1</h3>').replace(/^# (.*)$/gm,'<h2>$1</h2>')
          .replace(/\\*\\*([^*]+)\\*\\*/g,'<b>$1</b>')
          .replace(/\\[([^\\]]+)\\]\\((https?:[^)]+)\\)/g,'<a href="$2" target="_blank">$1</a>')
          .replace(/(^|\\n)[-*] (.*)/g,'$1<li>$2</li>').replace(/(<li>[\\s\\S]*?<\\/li>)/g,'<ul>$1</ul>')
          .replace(/\\n{2,}/g,'</p><p>').replace(/\\n/g,'<br>');}
        function hash(s){var h=2166136261;for(var i=0;i<s.length;i++){h^=s.charCodeAt(i);h=Math.imul(h,16777619);}return h>>>0;}
        function avatar(id){var h=hash(id),hue=h%360,c='hsl('+hue+',52%,58%)',cells='';
          for(var y=0;y<5;y++)for(var x=0;x<3;x++){if((h>>(y*3+x))&1){var xs=[x,4-x];for(var k=0;k<xs.length;k++)cells+='<rect x="'+(xs[k]*10)+'" y="'+(y*10)+'" width="10" height="10"/>';}}
          return '<svg viewBox="0 0 50 50" fill="'+c+'"><rect width="50" height="50" fill="#f1f1f3"/>'+cells+'</svg>';}
        function auto(){cin.style.height='auto';cin.style.height=Math.min(cin.scrollHeight,window.innerHeight*0.34)+'px';}
        cin.addEventListener('input',auto);
        cin.addEventListener('keydown',function(e){if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();start();}});
        root.querySelector('.sdec').addEventListener('click',function(){naAgents=Math.max(1,naAgents-1);snum.textContent=naAgents;});
        root.querySelector('.sinc').addEventListener('click',function(){naAgents=Math.min(64,naAgents+1);snum.textContent=naAgents;});
        [].forEach.call(root.querySelectorAll('.chip'),function(c){c.addEventListener('click',function(){cin.value=c.textContent;auto();cin.focus();});});
        function setStat(){bstat.textContent=spawned?(live+' working · '+spawned+' agents'):'';bcount.textContent=spawned?(spawned+(naAgents?'':'')+' agents'):'';}
        function relayout(){var c=order.length;grid.classList.toggle('tiny',c>24);grid.classList.toggle('mini',c>80);}
        function omsg(role,html){var d=document.createElement('div');d.className='omsg '+role;
          d.innerHTML=(role==='orch'?'<div class="who"><span class="glyph"></span>Orchestrator</div>':'<div class="who">You</div>')+'<div class="bubble">'+html+'</div>';
          olog.appendChild(d);olog.scrollTop=olog.scrollHeight;if(G)G.from(d,{opacity:0,y:8,duration:.35});return d;}
        var activityEl=null,acts=[];
        function activity(line){if(!activityEl){activityEl=document.createElement('div');activityEl.className='activity';olog.appendChild(activityEl);}
          acts.unshift(line);acts=acts.slice(0,6);activityEl.innerHTML=acts.map(function(a){return '<div class="aln">'+esc(a)+'</div>';}).join('');olog.scrollTop=olog.scrollHeight;}
        function tile(id,task){var el=document.createElement('div');el.className='tile';el.dataset.s='thinking';
          el.innerHTML='<span class="ring"></span><span class="av">'+avatar(id)+'</span><span class="tid">'+esc(id)+'</span>';
          el.addEventListener('click',function(){openDetail(id);});grid.appendChild(el);
          if(G)G.from(el,{scale:.5,opacity:0,duration:.35,ease:'back.out(1.7)'});return el;}
        function openDetail(id){var a=agents[id];if(!a)return;
          detail.hidden=false;
          var steps=a.steps.map(function(s){return '<div class="step"><b>'+esc(s[0])+'</b><span>'+esc(s[1])+'</span></div>';}).join('');
          var srcs=a.sources.map(function(s){return '<div class="src"><div class="surl">'+esc(s.url)+'</div><div class="sprev">'+esc(s.preview)+'</div></div>';}).join('');
          detail.innerHTML='<div class="dh"><span class="av">'+avatar(id)+'</span><b>'+esc(id)+'</b><button class="dx">×</button></div>'+
            '<div class="dtask">'+esc(a.task)+'</div>'+
            '<div class="sec">Reasoning</div>'+(steps||'<div class="step">—</div>')+
            (a.sources.length?('<div class="sec">Sources · '+a.sources.length+'</div>'+srcs):'')+
            (a.finding?('<div class="sec">Finding</div><div class="find">'+esc(a.finding)+'</div>'):'');
          detail.querySelector('.dx').addEventListener('click',function(){detail.hidden=true;});
          if(G)G.from(detail,{x:30,opacity:0,duration:.3,ease:'power3.out'});}
        function loadHistory(){fetch('/sessions').then(function(r){return r.json();}).then(function(rows){
          var rc=root.querySelector('.recent');if(!rc)return;if(!rows||!rows.length){rc.innerHTML='';return;}
          rc.innerHTML='<div class="rh">Recent</div>'+rows.map(function(s){return '<div class="ritem" data-id="'+s.id+'"><span class="rq">'+esc(s.query)+'</span><span class="rmeta">'+s.agents+' · '+esc((s.created_at||'').slice(0,10))+'</span></div>';}).join('');
          [].forEach.call(rc.querySelectorAll('.ritem'),function(el){el.addEventListener('click',function(){openSession(el.dataset.id);});});
        }).catch(function(){});}
        function reset(query){olog.innerHTML='';grid.innerHTML='';detail.hidden=true;agents={};order=[];live=0;spawned=0;acts=[];activityEl=null;newbtn.hidden=false;
          omsg('user',esc(query));}
        function openSession(id){fetch('/sessions/'+id).then(function(r){return r.json();}).then(function(s){
          if(!s||!s.query)return;reset(s.query);bstat.textContent=(s.agents||0)+' agents · saved';
          (s.findings||[]).forEach(function(f){var fid=f.id||('a'+(order.length+1));order.push(fid);
            var a={el:tile(fid,f.subtask||''),task:f.subtask||'',steps:[],sources:[],finding:f.finding||''};a.el.dataset.s='done';agents[fid]=a;});
          relayout();omsg('orch','<h3>Report</h3><p>'+md(s.report||'')+'</p>');
        }).catch(function(){});}
        function ev(e){
          if(e.type==='fleet'){omsg('orch','Researching <b>'+esc(e.task)+'</b>. I\\'ll break this into focused sub-questions and dispatch agents in rounds, reading their reports between each.');return;}
          if(e.type==='round'){activityEl=null;acts=[];omsg('orch','<b>Round '+e.n+'</b> · dispatching '+e.dispatching+' agents');return;}
          if(e.type==='digest'){omsg('orch',e.note||'');return;}
          if(e.type==='spawn'){order.push(e.id);agents[e.id]={el:tile(e.id,e.query),task:e.query||'',steps:[['task',e.query||'']],sources:[],finding:''};
            spawned++;live++;setStat();relayout();activity('dispatched '+e.id+' → '+(e.query||''));return;}
          var a=agents[e.id];
          if(e.type==='state'){if(!a)return;a.el.dataset.s=e.status;
            if(e.status==='searching')a.steps.push(['search',e.action||'']);else if(e.status==='reading')a.steps.push(['read',e.url||e.action||'']);else if(e.status==='thinking'&&e.action)a.steps.push(['think',e.action]);
            if(e.status==='searching')activity(e.id+' searching: '+(e.action||''));else if(e.status==='reading')activity(e.id+' reading '+(e.url||''));
            if(!detail.hidden&&detail.dataset.id===e.id)openDetail(e.id);return;}
          if(e.type==='page'){if(!a)return;a.sources.push({url:e.url||'',preview:e.preview||''});return;}
          if(e.type==='done'){if(!a)return;if(a.el.dataset.s!=='done')live--;a.el.dataset.s='done';a.finding=e.finding||'';setStat();activity('✓ '+e.id+' reported');return;}
          if(e.type==='synth'){omsg('orch','<span class="shimmer">Compiling '+spawned+' findings into a report…</span>');return;}
          if(e.type==='report'){omsg('orch','<h3>Final report</h3><p>'+md(e.content||'')+'</p>');return;}
          if(e.type==='fleet_done'||e.type==='end'){if(es){es.close();es=null;}return;}
        }
        function start(){var query=(cin.value||'').trim();if(!query)return;reset(query);cin.value='';auto();bstat.textContent='dispatching '+naAgents+' agents…';
          if(es)es.close();es=new EventSource('/live/'+encodeURIComponent(stream)+'?q='+encodeURIComponent(query)+'&max='+naAgents);
          es.onmessage=function(m){try{ev(JSON.parse(m.data));}catch(_){}};es.onerror=function(){if(es){es.close();es=null;}};}
        root.querySelector('.composer').addEventListener('submit',function(x){x.preventDefault();start();});
        newbtn.addEventListener('click',function(){if(es){es.close();es=null;}location.reload();});
        loadHistory();
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

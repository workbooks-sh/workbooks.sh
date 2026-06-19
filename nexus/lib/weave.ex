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
        <main class="stage">
          <section class="welcome">
            <h1>What should the swarm research?</h1>
            <p class="sub">A fleet of agents investigates your question in parallel — then writes one report.</p>
            <div class="chips">
              <button class="chip" type="button">How does BEAM concurrency work?</button>
              <button class="chip" type="button">Compare WebAssembly runtimes</button>
              <button class="chip" type="button">State of local-first sync engines</button>
            </div>
            <div class="recent"></div>
          </section>
          <section class="convo" hidden>
            <article class="report" hidden></article>
            <div class="msgs"></div>
          </section>
        </main>
        <div class="dock">
          <form class="composer">
            <textarea class="cin" rows="1" placeholder="Ask the swarm anything…"></textarea>
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
        </div>
      </div>
      <style>
      .aiapp{--bg:#fafafa;--surface:#fff;--line:#e7e7ea;--line2:#ededf0;--ink:#18181b;--muted:#71717a;--subtle:#a1a1aa;
        --accent:#6366f1;--accent-soft:#eef0ff;--searching:#3b82f6;--reading:#f59e0b;--thinking:#8b5cf6;--done:#10b981;
        position:fixed;inset:0;background:var(--bg);color:var(--ink);display:flex;flex-direction:column;
        font:14.5px/1.6 ui-sans-serif,system-ui,-apple-system,"Inter",sans-serif;-webkit-font-smoothing:antialiased}
      .aiapp *{box-sizing:border-box}
      .aiapp .bar{flex:none;display:flex;align-items:center;gap:.7rem;padding:.7rem 1.1rem;backdrop-filter:saturate(1.6) blur(8px);background:#fafafacc;border-bottom:1px solid var(--line2);z-index:5}
      .aiapp .logo{display:flex;align-items:center;gap:.5rem;font-weight:600;letter-spacing:-.01em}
      .aiapp .glyph{width:16px;height:16px;border-radius:5px;background:conic-gradient(from 210deg,var(--accent),#a855f7,#22d3ee,var(--accent));box-shadow:0 0 0 1px #ffffff inset}
      .aiapp .bstat{flex:1;color:var(--subtle);font-size:.82em;font-variant-numeric:tabular-nums}
      .aiapp .newbtn{background:var(--surface);border:1px solid var(--line);color:var(--ink);border-radius:9px;padding:.4rem .8rem;font-size:.85em;cursor:pointer}
      .aiapp .newbtn:hover{background:#f4f4f5}
      .aiapp .stage{flex:1;min-height:0;overflow-y:auto;scroll-behavior:smooth}
      .aiapp .welcome{max-width:680px;margin:0 auto;padding:14vh 1.2rem 2rem;text-align:center}
      .aiapp .welcome h1{margin:0 0 .4rem;font-size:2rem;letter-spacing:-.025em;font-weight:640}
      .aiapp .welcome .sub{margin:0 0 1.6rem;color:var(--muted)}
      .aiapp .chips{display:flex;gap:.5rem;flex-wrap:wrap;justify-content:center;margin-bottom:1.4rem}
      .aiapp .chip{background:var(--surface);border:1px solid var(--line);color:var(--muted);border-radius:999px;padding:.45rem .9rem;font-size:.85em;cursor:pointer;transition:.15s}
      .aiapp .chip:hover{color:var(--ink);border-color:var(--accent);box-shadow:0 1px 0 #0000000a}
      .aiapp .recent{max-width:520px;margin:1.6rem auto 0;text-align:left}
      .aiapp .rh{color:var(--subtle);font-size:.74em;text-transform:uppercase;letter-spacing:.06em;margin-bottom:.3rem}
      .aiapp .ritem{display:flex;gap:.6rem;align-items:baseline;padding:.55rem .2rem;border-top:1px solid var(--line2);cursor:pointer}
      .aiapp .ritem:hover .rq{color:var(--accent)}
      .aiapp .rq{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .aiapp .rmeta{flex:none;color:var(--subtle);font-size:.78em}
      .aiapp .convo{max-width:760px;margin:0 auto;padding:1.2rem 1.1rem 9rem}
      .aiapp .report{background:var(--surface);border:1px solid var(--line);border-radius:16px;padding:1.3rem 1.5rem;margin-bottom:1rem;box-shadow:0 1px 2px #0000000a,0 12px 40px -24px #6366f133}
      .aiapp .report .rt{display:flex;align-items:center;gap:.5rem;font-weight:620;margin-bottom:.5rem}
      .aiapp .report .rt .glyph{width:18px;height:18px}
      .aiapp .report h2{margin:.1rem 0 .5rem;font-size:1.05rem}.aiapp .report h3{margin:1rem 0 .3rem;font-size:.96rem}
      .aiapp .report p{margin:.45rem 0}.aiapp .report ul{margin:.45rem 0;padding-left:1.2rem}.aiapp .report li{margin:.15rem 0}
      .aiapp .report a{color:var(--accent);text-decoration:none}.aiapp .report a:hover{text-decoration:underline}
      .aiapp .shimmer{background:linear-gradient(90deg,#a1a1aa,#18181b,#a1a1aa);background-size:200% 100%;-webkit-background-clip:text;background-clip:text;color:transparent;animation:sh 1.6s linear infinite}
      @keyframes sh{to{background-position:-200% 0}}
      .aiapp .msg{background:var(--surface);border:1px solid var(--line);border-radius:14px;margin-bottom:.7rem;overflow:hidden}
      .aiapp .mhead{display:flex;align-items:center;gap:.6rem;padding:.7rem .9rem}
      .aiapp .dot{width:8px;height:8px;border-radius:50%;flex:none;background:var(--subtle)}
      .aiapp .mlabel{font-size:.72em;color:var(--subtle);font-variant-numeric:tabular-nums;flex:none}
      .aiapp .mtask{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--ink)}
      .aiapp .mtag{flex:none;font-size:.72em;color:var(--muted);text-transform:capitalize}
      .aiapp .msg[data-s=searching] .dot{background:var(--searching)}.aiapp .msg[data-s=reading] .dot{background:var(--reading)}
      .aiapp .msg[data-s=thinking] .dot{background:var(--thinking)}.aiapp .msg[data-s=done] .dot{background:var(--done)}
      .aiapp .msg[data-s=searching] .dot,.aiapp .msg[data-s=reading] .dot,.aiapp .msg[data-s=thinking] .dot{animation:pulse 1.3s ease-in-out infinite}
      @keyframes pulse{0%,100%{box-shadow:0 0 0 0 currentColor;opacity:1}50%{box-shadow:0 0 0 4px #6366f100;opacity:.6}}
      .aiapp .panel{border-top:1px solid var(--line2)}
      .aiapp .ptoggle{display:flex;align-items:center;gap:.4rem;width:100%;background:none;border:0;color:var(--muted);font:inherit;font-size:.85em;padding:.5rem .9rem;cursor:pointer;text-align:left}
      .aiapp .ptoggle:hover{color:var(--ink)}
      .aiapp .chev{transition:transform .18s;color:var(--subtle)}
      .aiapp .panel.open .chev{transform:rotate(90deg)}
      .aiapp .pbody{display:none;padding:0 .9rem .7rem}.aiapp .panel.open .pbody{display:block}
      .aiapp .step{display:flex;gap:.5rem;padding:.16rem 0;color:var(--muted);font-size:.86em}
      .aiapp .step b{color:var(--ink);font-weight:500;flex:none;width:4.6rem;text-transform:capitalize}
      .aiapp .src{display:block;padding:.4rem .55rem;margin:.3rem 0;border:1px solid var(--line2);border-radius:9px;background:#fcfcfd;cursor:pointer}
      .aiapp .src .surl{font-size:.8em;color:var(--accent);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .aiapp .src .sprev{display:none;font-size:.82em;color:var(--muted);margin-top:.3rem;max-height:8em;overflow:hidden;white-space:pre-wrap}
      .aiapp .src.open .sprev{display:block}
      .aiapp .finding{padding:.7rem .9rem;border-top:1px solid var(--line2);color:var(--ink)}
      .aiapp .dock{position:absolute;left:0;right:0;bottom:0;padding:0 1rem 1.1rem;background:linear-gradient(180deg,#fafafa00,#fafafa 38%);pointer-events:none}
      .aiapp .composer{pointer-events:auto;max-width:720px;margin:0 auto;background:var(--surface);border:1px solid var(--line);border-radius:18px;padding:.7rem .7rem .55rem;box-shadow:0 2px 6px #0000000d,0 18px 50px -22px #00000026;transition:border-color .15s,box-shadow .15s}
      .aiapp .composer:focus-within{border-color:#c7c9ff;box-shadow:0 2px 6px #0000000d,0 18px 50px -20px #6366f140}
      .aiapp .cin{width:100%;border:0;outline:0;resize:none;background:none;color:var(--ink);font:inherit;font-size:1rem;padding:.3rem .4rem;max-height:40vh}
      .aiapp .cin::placeholder{color:var(--subtle)}
      .aiapp .cbar{display:flex;align-items:center;gap:.5rem;margin-top:.35rem}
      .aiapp .stepper{display:flex;align-items:center;gap:.3rem;background:#f4f4f5;border:1px solid var(--line);border-radius:999px;padding:.15rem .3rem;color:var(--muted);font-size:.82em}
      .aiapp .stepper button{width:20px;height:20px;border:0;border-radius:50%;background:none;color:var(--muted);cursor:pointer;font-size:1em;line-height:1}
      .aiapp .stepper button:hover{background:#e4e4e7;color:var(--ink)}
      .aiapp .snum{min-width:1.1em;text-align:center;color:var(--ink);font-weight:600}.aiapp .slbl{margin-right:.15rem}
      .aiapp .grow{flex:1}
      .aiapp .cstat{color:var(--subtle);font-size:.8em}
      .aiapp .send{width:34px;height:34px;flex:none;border:0;border-radius:11px;background:var(--accent);color:#fff;display:grid;place-items:center;cursor:pointer;transition:.15s}
      .aiapp .send:hover{filter:brightness(1.08)}.aiapp .send:disabled{background:#d4d4d8;cursor:default}
      </style>
      <script>(function(){
        var root=document.getElementById('app-#{esc(name)}'); if(!root) return;
        var G=window.gsap, stream=root.dataset.stream, es=null, agents={}, live=0, spawned=0, naAgents=8;
        var welcome=root.querySelector('.welcome'), convo=root.querySelector('.convo'), msgs=root.querySelector('.msgs');
        var report=root.querySelector('.report'), recent=root.querySelector('.recent'), bstat=root.querySelector('.bar .bstat');
        var cin=root.querySelector('.cin'), snum=root.querySelector('.snum'), send=root.querySelector('.send'), newbtn=root.querySelector('.newbtn');
        function esc(s){return (s==null?'':String(s)).replace(/[&<>]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;'}[c];});}
        function md(t){return esc(t)
          .replace(/^### (.*)$/gm,'<h3>$1</h3>').replace(/^## (.*)$/gm,'<h3>$1</h3>').replace(/^# (.*)$/gm,'<h2>$1</h2>')
          .replace(/\\*\\*([^*]+)\\*\\*/g,'<b>$1</b>')
          .replace(/\\[([^\\]]+)\\]\\((https?:[^)]+)\\)/g,'<a href="$2" target="_blank">$1</a>')
          .replace(/(^|\\n)[-*] (.*)/g,'$1<li>$2</li>').replace(/(<li>[\\s\\S]*?<\\/li>)/g,'<ul>$1</ul>')
          .replace(/\\n{2,}/g,'</p><p>').replace(/\\n/g,'<br>');}
        function auto(){cin.style.height='auto';cin.style.height=Math.min(cin.scrollHeight,window.innerHeight*0.4)+'px';}
        cin.addEventListener('input',auto);
        cin.addEventListener('keydown',function(e){if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();start();}});
        root.querySelector('.sdec').addEventListener('click',function(){naAgents=Math.max(1,naAgents-1);snum.textContent=naAgents;});
        root.querySelector('.sinc').addEventListener('click',function(){naAgents=Math.min(48,naAgents+1);snum.textContent=naAgents;});
        [].forEach.call(root.querySelectorAll('.chip'),function(c){c.addEventListener('click',function(){cin.value=c.textContent;auto();cin.focus();});});
        function setStat(){bstat.textContent = spawned? (live+' working · '+spawned+' agents') : '';}
        function panel(title){var p=document.createElement('div');p.className='panel';
          p.innerHTML='<button class="ptoggle"><svg class="chev" width="12" height="12" viewBox="0 0 24 24" fill="none"><path d="M9 6l6 6-6 6" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"/></svg><span class="plabel">'+esc(title)+'</span></button><div class="pbody"></div>';
          p.querySelector('.ptoggle').addEventListener('click',function(){p.classList.toggle('open');});
          return p;}
        function agentEl(id,task){
          var el=document.createElement('div');el.className='msg';el.dataset.s='thinking';
          el.innerHTML='<div class="mhead"><span class="dot"></span><span class="mlabel">'+esc(id)+'</span><span class="mtask">'+esc(task||'')+'</span><span class="mtag">thinking</span></div>';
          var rp=panel('Reasoning');rp.classList.add('reasoning');el.appendChild(rp);
          var sp=panel('Sources');sp.classList.add('sources');sp.hidden=true;el.appendChild(sp);
          msgs.appendChild(el);
          if(G)G.from(el,{y:14,opacity:0,duration:.42,ease:'power3.out'});
          return {el:el,steps:rp.querySelector('.pbody'),rpanel:rp,sources:sp.querySelector('.pbody'),spanel:sp,srcN:0};
        }
        function step(a,label,text){var d=document.createElement('div');d.className='step';d.innerHTML='<b>'+esc(label)+'</b><span>'+esc(text)+'</span>';a.steps.appendChild(d);if(G)G.from(d,{opacity:0,x:-6,duration:.3});}
        function loadHistory(){fetch('/sessions').then(function(r){return r.json();}).then(function(rows){
          if(!rows||!rows.length){recent.innerHTML='';return;}
          recent.innerHTML='<div class="rh">Recent</div>'+rows.map(function(s){
            return '<div class="ritem" data-id="'+s.id+'"><span class="rq">'+esc(s.query)+'</span><span class="rmeta">'+s.agents+' agents · '+esc((s.created_at||'').slice(0,10))+'</span></div>';}).join('');
          [].forEach.call(recent.querySelectorAll('.ritem'),function(el){el.addEventListener('click',function(){openSession(el.dataset.id);});});
        }).catch(function(){});}
        function showConvo(query){
          welcome.hidden=true;convo.hidden=false;newbtn.hidden=false;msgs.innerHTML='';report.hidden=true;agents={};live=0;spawned=0;setStat();
          if(G)G.from(convo,{opacity:0,y:8,duration:.4});
        }
        function showReport(html,thinking){
          report.hidden=false;
          report.innerHTML='<div class="rt"><span class="glyph"></span>'+(thinking?'<span class="shimmer">Writing report…</span>':'Final report')+'</div>'+(thinking?'':('<div class="rbody"><p>'+html+'</p></div>'));
          if(!thinking&&G)G.from(report,{opacity:0,y:14,duration:.5,ease:'power3.out'});
        }
        function openSession(id){fetch('/sessions/'+id).then(function(r){return r.json();}).then(function(s){
          if(!s||!s.query)return;showConvo(s.query);bstat.textContent=(s.agents||0)+' agents · saved';
          showReport(md(s.report||''),false);
          (s.findings||[]).forEach(function(f){var a=agentEl(f.id||'',f.subtask||'');a.el.dataset.s='done';a.el.querySelector('.mtag').textContent='done';
            var fd=document.createElement('div');fd.className='finding';fd.textContent=f.finding||'';a.el.appendChild(fd);});
        }).catch(function(){});}
        function ev(e){
          if(e.type==='fleet')return;
          if(e.type==='spawn'){agents[e.id]=agentEl(e.id,e.query);step(agents[e.id],'task',e.query||'');spawned++;live++;setStat();return;}
          var a=agents[e.id];
          if(e.type==='state'){if(!a)return;a.el.dataset.s=e.status;a.el.querySelector('.mtag').textContent=e.status;
            if(e.action)a.el.querySelector('.mtask').textContent=e.action;
            if(e.status==='searching')step(a,'search',e.action||'');else if(e.status==='reading')step(a,'read',e.url||e.action||'');else if(e.status==='thinking'&&e.action)step(a,'think',e.action);
            if(e.status!=='done')a.rpanel.classList.add('open');return;}
          if(e.type==='page'){if(!a)return;a.spanel.hidden=false;a.srcN++;a.spanel.querySelector('.plabel').textContent='Sources · '+a.srcN;
            var s=document.createElement('div');s.className='src';s.innerHTML='<div class="surl">'+esc(e.url||'')+'</div><div class="sprev">'+esc(e.preview||'')+'</div>';
            s.addEventListener('click',function(){s.classList.toggle('open');});a.sources.appendChild(s);return;}
          if(e.type==='done'){if(!a)return;if(a.el.dataset.s!=='done')live--;a.el.dataset.s='done';a.el.querySelector('.mtag').textContent='done';a.rpanel.classList.remove('open');
            if(e.finding){a.el.querySelector('.mtask').textContent=e.finding;var fd=document.createElement('div');fd.className='finding';fd.textContent=e.finding;a.el.appendChild(fd);}setStat();return;}
          if(e.type==='synth'){showReport('',true);return;}
          if(e.type==='report'){showReport(md(e.content||''),false);convo.parentNode.scrollTop=0;return;}
          if(e.type==='fleet_done'||e.type==='end'){if(es){es.close();es=null;}return;}
        }
        function start(){
          var query=(cin.value||'').trim();if(!query)return;
          showConvo(query);bstat.textContent='dispatching '+naAgents+' agents…';
          if(es)es.close();
          es=new EventSource('/live/'+encodeURIComponent(stream)+'?q='+encodeURIComponent(query)+'&max='+naAgents);
          es.onmessage=function(m){try{ev(JSON.parse(m.data));}catch(_){}};
          es.onerror=function(){if(es){es.close();es=null;}};
        }
        root.querySelector('.composer').addEventListener('submit',function(x){x.preventDefault();start();});
        newbtn.addEventListener('click',function(){if(es){es.close();es=null;}convo.hidden=true;welcome.hidden=false;newbtn.hidden=true;bstat.textContent='';loadHistory();cin.value='';auto();cin.focus();});
        if(G)G.from(welcome,{opacity:0,y:10,duration:.5,ease:'power2.out'});
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

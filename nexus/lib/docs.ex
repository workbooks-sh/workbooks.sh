defmodule Nexus.Docs do
  @moduledoc """
  Site-mode render for an `app :docs do … section … page … end` workbook — the docs SPA the docs app
  declares but that wasn't built yet. Parses the app block's sections + pages, renders each page's
  prose (reusing `Nexus.SSR`'s node renderer), and emits a single navigable app: a sidebar of
  sections → pages, a content area with one page shown at a time, and a small history router that
  intercepts the real `/path` links (so `[link](/introduction/what-is-a-workbook)` just works).
  """

  @doc "Render the docs app at `root`. `rn` = SSR.render_node/3, `pt` = SSR.page_title/1."
  def render(root, app, ctx, rn, pt) do
    meta = parse_app(app.ast)

    loaded =
      for s <- meta.sections, p <- s.pages, into: %{} do
        {p, load_page(root, p, ctx, rn, pt)}
      end

    sidebar = sidebar_html(meta.sections, loaded)

    articles =
      Enum.map_join(meta.sections, "\n", fn s ->
        Enum.map_join(s.pages, "\n", fn p ->
          {_t, html} = Map.get(loaded, p, {p, ""})
          ~s(<article class="page" data-page="#{he(p)}" hidden><div class="prose">#{html}</div></article>)
        end)
      end)

    first =
      case meta.sections do
        [%{pages: [p | _]} | _] -> p
        _ -> ""
      end

    shell(meta.title, sidebar, articles, first)
  end

  # ── parse the app block ──────────────────────────────────────────────────────

  defp parse_app(ast) do
    stmts = ast |> app_body() |> block_stmts()
    title = Enum.find_value(stmts, "Docs", fn {:title, _, [t]} when is_binary(t) -> t; _ -> nil end)

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

  # ── load + render a page ─────────────────────────────────────────────────────

  defp load_page(root, path, ctx, rn, pt) do
    file = Path.join(root, path <> ".work")

    nodes =
      case File.read(file) do
        {:ok, c} -> Nexus.Literate.parse(c)
        _ -> []
      end

    ctx = Map.put(ctx, :app, false)
    html = Enum.map_join(nodes, "\n", fn n -> rn.(n, %{}, ctx) end)
    {pt.(nodes), html}
  end

  defp sidebar_html(sections, loaded) do
    Enum.map_join(sections, "\n", fn s ->
      links =
        Enum.map_join(s.pages, "", fn p ->
          {t, _} = Map.get(loaded, p, {p, ""})
          ~s(<a class="pl" data-page="#{he(p)}" href="/#{he(p)}">#{he(t)}</a>)
        end)

      ~s(<div class="sx"><div class="sxh">#{he(s.title)}</div>#{links}</div>)
    end)
  end

  # ── shell + theme + router ───────────────────────────────────────────────────

  defp shell(title, sidebar, articles, first) do
    """
    <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>#{he(title)} · docs</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&family=Geist+Mono:wght@400;500&display=swap" rel="stylesheet">
    <style>#{css()}</style></head><body>
    <div class="doc">
      <aside class="side">
        <a class="brand" data-page="#{he(first)}" href="/#{he(first)}">❧ #{he(title)}</a>
        <nav>#{sidebar}</nav>
      </aside>
      <main class="main">#{articles}</main>
    </div>
    <script>#{router()}</script>
    </body></html>
    """
  end

  defp css do
    """
    *{box-sizing:border-box}
    :root{--bg:#faf9f4;--paper:#fff;--ink:#16161a;--soft:#6c6c72;--line:#e8e5dc;--accent:#13a93a;
      --sans:'Geist',system-ui,sans-serif;--mono:'Geist Mono',ui-monospace,Menlo,monospace}
    body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.7 var(--sans)}
    .doc{display:flex;align-items:flex-start;max-width:1180px;margin:0 auto}
    .side{position:sticky;top:0;height:100vh;width:264px;flex:none;padding:26px 20px;overflow-y:auto;border-right:1px solid var(--line)}
    .brand{display:block;font-size:18px;font-weight:650;letter-spacing:-.01em;color:var(--ink);text-decoration:none;margin-bottom:22px}
    .sx{margin-bottom:20px}
    .sxh{font-size:11.5px;text-transform:uppercase;letter-spacing:.08em;color:#a4a097;font-weight:600;margin-bottom:7px}
    .pl{display:block;color:var(--soft);text-decoration:none;font-size:14.5px;padding:5px 10px;border-radius:8px;margin:1px 0;line-height:1.4}
    .pl:hover{color:var(--ink);background:#f1efe7}
    .pl.on{color:var(--ink);background:#eef2ec;font-weight:550;box-shadow:inset 2px 0 0 var(--accent)}
    .main{flex:1;min-width:0;padding:54px 60px 120px;max-width:780px}
    .prose h1{font-size:32px;font-weight:700;letter-spacing:-.022em;margin:0 0 18px;line-height:1.15}
    .prose h2{font-size:21px;font-weight:600;margin:38px 0 12px;padding-bottom:8px;border-bottom:1px solid var(--line)}
    .prose h3{font-size:16.5px;font-weight:600;margin:26px 0 8px}
    .prose p{margin:0 0 15px;color:#2b2b30}
    .prose ul{margin:0 0 15px;padding-left:22px} .prose li{margin:6px 0}
    .prose a{color:#1f7d33;text-decoration:none;border-bottom:1px solid #cfe3d3} .prose a:hover{border-color:#1f7d33}
    .prose strong{font-weight:600;color:var(--ink)}
    .prose code{font-family:var(--mono);font-size:.88em;background:#f0eee5;padding:1.5px 6px;border-radius:5px}
    .prose pre{margin:18px 0;padding:14px 16px;background:#f7f5ee;border:1px solid var(--line);border-radius:10px;overflow-x:auto;
      font:13px/1.6 var(--mono)}
    .prose pre code{background:none;padding:0;font-size:13px}
    .prose blockquote{margin:18px 0;padding:12px 18px;background:#fbfaf5;border-left:3px solid var(--accent);border-radius:6px;color:#54545a}
    .prose .unit{margin:18px 0;border:1px solid var(--line);border-radius:12px;overflow:hidden}
    .prose .unit pre{margin:0;padding:14px 16px;overflow-x:auto;font:13px/1.6 var(--mono);background:var(--paper)}
    @media(max-width:840px){.side{display:none}.main{padding:32px 22px}}
    """
  end

  defp router do
    """
    (function(){
      var base=new URL(document.baseURI).pathname;
      function curKey(){var p=location.pathname;return p.indexOf(base)===0?p.slice(base.length):p.replace(/^\\//,'');}
      function show(k){
        var arts=document.querySelectorAll('.page'),hit=false;
        arts.forEach(function(a){var on=a.dataset.page===k;a.hidden=!on;if(on)hit=true;});
        if(!hit&&arts[0]){arts[0].hidden=false;k=arts[0].dataset.page;}
        document.querySelectorAll('.pl').forEach(function(l){l.classList.toggle('on',l.dataset.page===k);});
        window.scrollTo(0,0);
      }
      function go(k){history.pushState({},'',base+k);show(k);}
      document.addEventListener('click',function(e){
        var a=e.target.closest('a[data-page],a[href^="/"]');if(!a)return;
        var k=a.dataset.page||a.getAttribute('href').replace(/^\\//,'');
        if(document.querySelector('.page[data-page="'+(window.CSS&&CSS.escape?CSS.escape(k):k)+'"]')){e.preventDefault();go(k);}
      });
      window.addEventListener('popstate',function(){show(curKey());});
      show(curKey());
    })();
    """
  end

  defp he(s), do: s |> to_string() |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;") |> String.replace("\"", "&quot;")
end

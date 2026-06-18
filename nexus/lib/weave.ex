defmodule Nexus.Weave do
  @moduledoc """
  A workbook (a folder of `.work` files) → ONE self-contained `.html`. A workbook IS an HTML file:
  the browser renders it, no runtime required. Prose narrates; `show Resource` directives render
  live data tables from `Nexus.Store`; unit code embeds. The data layer is pluggable (baked /
  local SQLite / server) behind one API — see docs/WEAVE-PLAN.md.

  Render-aware: resources in the folder are compiled, and `show <Resource>` becomes a table of
  that resource's rows (columns from `__fields__`, every cell XSS-escaped, graceful empty-state).
  """

  @doc "Weave a workbook folder into one self-contained HTML string."
  def weave(root) do
    pages = root |> files() |> Enum.map(fn p -> {Path.relative_to(p, root), Nexus.Literate.parse(File.read!(p))} end)
    render(pages, resources(pages))
  end

  # index.work is the composition root — it leads; the rest follow alphabetically.
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

  # name → compiled struct module, for every `resource` unit in the folder.
  defp resources(pages) do
    for {_f, nodes} <- pages, n <- nodes, n.type == :code, n.kind == "resource", into: %{} do
      {n.name, safe_compile(n)}
    end
  end

  defp safe_compile(node) do
    Nexus.Resource.compile(node)
  rescue
    _ -> nil
  end

  defp render(pages, res) do
    body = Enum.map_join(pages, "\n", &page(&1, res))

    """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><title>#{esc(title(pages))}</title>
    <style>#{css()}</style></head>
    <body>
    #{nav(pages)}#{body}
    </body></html>
    """
  end

  defp page({name, nodes}, res) do
    ~s(<section class="file" id="#{anchor(name)}" data-file="#{esc(name)}">\n) <>
      Enum.map_join(nodes, "\n", &render_node(&1, res)) <> "\n</section>"
  end

  defp render_node(%{type: :heading, level: l, text: t}, _res), do: "  <h#{l}>#{inline(t)}</h#{l}>"

  defp render_node(%{type: :prose, text: t}, _res) do
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

  # `show <Resource>` → a live data table from the Store.
  defp render_node(%{type: :decl, text: "show " <> rest}, res) do
    name = rest |> String.split() |> List.first()
    render_show(name, Map.get(res, name))
  end

  defp render_node(%{type: :decl, text: t}, _res), do: ~s(  <pre class="decl">#{esc(t)}</pre>)

  defp render_node(%{type: :code, kind: k, name: n, body: b}, _res) do
    ~s(  <figure class="unit" data-unit="#{esc(k)}:#{esc(n)}">) <>
      ~s(<figcaption><span class="kind">#{esc(k)}</span> #{esc(n)}</figcaption>) <>
      ~s(<pre>#{esc(b)}</pre></figure>)
  end

  defp render_node(_, _res), do: ""

  defp render_show(name, nil),
    do: ~s(  <div class="data-missing">unknown resource <code>#{esc(name)}</code></div>)

  defp render_show(name, mod) do
    fields = Enum.map(mod.__fields__(), &elem(&1, 0))
    rows = Nexus.Store.all(mod)
    header = Enum.map_join(fields, "", &"<th>#{esc(&1)}</th>")

    body =
      if rows == [] do
        ~s(<tr><td colspan="#{max(length(fields), 1)}" class="empty">no rows yet</td></tr>)
      else
        Enum.map_join(rows, "", fn row ->
          "<tr>" <> Enum.map_join(fields, "", fn f -> "<td>#{esc(Map.get(row, f))}</td>" end) <> "</tr>"
        end)
      end

    ~s(  <table class="data" data-resource="#{esc(name)}"><caption>#{esc(name)}</caption><thead><tr>#{header}</tr></thead><tbody>#{body}</tbody></table>)
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
    .data-missing{color:#b00;font-size:.9em}
    nav.wb-nav{display:flex;gap:.8em;flex-wrap:wrap;padding:.6em 0;margin-bottom:1em;border-bottom:1px solid #e4e4e7;font-size:.9em}
    nav.wb-nav a{color:#555;text-decoration:none} nav.wb-nav a:hover{color:#000}
    """
  end
end

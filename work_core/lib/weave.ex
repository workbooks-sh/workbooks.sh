defmodule WorkCore.Weave do
  @moduledoc """
  The **static weaver** — the floor of the `wbundle-html` model: parse a `.work` tree (literate prose
  + `<kind> [lang] :name do … end` units) and assemble ONE self-contained `.html` workbook. Prose
  renders to HTML; each unit becomes a `<work-component>` custom element carrying its source, so the
  page is on-canon (a workbook IS HTML built from `work-*` elements) and renders in any browser with
  no engine. Dynamic hydration — compiling a unit to wasm + running it, baking live data — is the
  *nexus-backed* tier (`Nexus.Weave`), layered on top when a nexus is configured. Pure + local: no
  NIF, no network, so `work weave` works offline.
  """

  alias WorkCore.Literate

  @doc "Weave the `.work` tree under `dir` into one self-contained HTML string."
  def static(dir, opts \\ []) do
    pages =
      dir
      |> files()
      |> Enum.map(fn p -> {Path.relative_to(p, dir), Literate.parse(File.read!(p))} end)

    title = Keyword.get(opts, :title) || tree_title(pages) || Path.basename(Path.expand(dir))
    body = Enum.map_join(pages, "\n", fn {path, nodes} -> page(path, nodes) end)

    """
    <!doctype html>
    <html lang="en"><head>
    <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{esc(title)}</title>
    <style>#{css()}</style>
    </head><body>
    <main class="wb">
    #{body}
    </main>
    </body></html>
    """
  end

  @doc "Weave `dir` and write the result to `out`. Returns `{:ok, out, byte_size}`."
  def to_file(dir, out, opts \\ []) do
    html = static(dir, opts)
    File.write!(out, html)
    {:ok, out, byte_size(html)}
  end

  @doc "How many units (`:code` nodes) the tree holds — for the CLI summary."
  def unit_count(dir) do
    dir |> files() |> Enum.flat_map(fn p -> p |> File.read!() |> Literate.parse() end) |> Enum.count(&(&1.type == :code))
  end

  # ── page + node rendering ───────────────────────────────────────────────────────────────────
  defp page(path, nodes) do
    ~s(<section class="page" data-src="#{esc(path)}">\n) <> Enum.map_join(nodes, "\n", &render_node/1) <> "\n</section>"
  end

  defp render_node(%{type: :heading, level: l, text: t}), do: "<h#{l}>#{inline(t)}</h#{l}>"
  defp render_node(%{type: :prose, text: t}), do: "<p>#{inline(t)}</p>"
  defp render_node(%{type: :decl, text: t}), do: ~s(<pre class="decl">#{esc(t)}</pre>)

  defp render_node(%{type: :code} = u) do
    label = [u.kind, u.lang] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
    attrs = ~s(lang="#{esc(u.lang || "")}" name="#{esc(u.name || "")}" kind="#{esc(u.kind || "")}")

    ~s(<work-component #{attrs}>) <>
      ~s(<header class="unit"><span class="nm">:#{esc(u.name)}</span><span class="kn">#{esc(label)}</span></header>) <>
      ~s(<pre class="src"><code>#{esc(u.header)} do\n#{esc(u.body)}\nend</code></pre>) <>
      ~s(</work-component>)
  end

  defp render_node(_), do: ""

  # minimal inline markdown: `code`, [[backlink]], **bold**, escaping the rest.
  defp inline(text) do
    text
    |> esc()
    |> String.replace(~r/`([^`]+)`/, "<code>\\1</code>")
    |> String.replace(~r/\*\*([^*]+)\*\*/, "<strong>\\1</strong>")
    |> String.replace(~r/\[\[([^\]]+)\]\]/, ~s(<a class="ref" href="#\\1">\\1</a>))
  end

  defp tree_title(pages) do
    Enum.find_value(pages, fn {_p, nodes} ->
      case Enum.find(nodes, &(&1.type == :heading and &1.level == 1)) do
        %{text: t} -> t
        _ -> nil
      end
    end)
  end

  defp files(dir) do
    (Path.wildcard(Path.join(dir, "*.work")) ++ Path.wildcard(Path.join(dir, "**/*.work"))) |> Enum.uniq() |> Enum.sort()
  end

  defp esc(nil), do: ""
  defp esc(s), do: s |> to_string() |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")

  # The paper aesthetic — ink-on-paper, mono code, soft unit cards.
  defp css do
    """
    :root{--paper:#fbfaf3;--ink:#121316;--line:#e6e3d8;--mut:#6b7382;--mint:#aee5c2}
    *{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:16px/1.6 ui-sans-serif,system-ui,'Geist',sans-serif}
    .wb{max-width:780px;margin:0 auto;padding:56px 24px 120px}
    .page{padding:8px 0}h1{font-size:30px;letter-spacing:-.02em;margin:.4em 0}h2{font-size:22px;margin:1.4em 0 .4em}h3{font-size:18px}
    p{margin:.7em 0}a.ref{color:#2b6f4e;text-decoration:none;border-bottom:1px solid var(--mint)}
    code{font:13px/1.5 'Geist Mono',ui-monospace,monospace;background:rgba(18,19,22,.05);padding:.1em .3em;border-radius:4px}
    work-component{display:block;margin:18px 0;border:1px solid var(--line);border-radius:12px;overflow:hidden;background:#fff}
    .unit{display:flex;justify-content:space-between;align-items:center;padding:9px 14px;border-bottom:1px solid var(--line);background:#fcfbf6}
    .unit .nm{font:600 13px 'Geist Mono',monospace}.unit .kn{font:11px 'Geist Mono',monospace;color:var(--mut);text-transform:uppercase;letter-spacing:.06em}
    pre.src{margin:0;padding:14px;overflow:auto}pre.src code{background:none;padding:0;display:block;white-space:pre}
    pre.decl{font:12px 'Geist Mono',monospace;color:var(--mut);background:none;padding:0;margin:.4em 0}
    """
  end
end

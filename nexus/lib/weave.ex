defmodule Nexus.Weave do
  @moduledoc """
  A workbook (a folder of `.work` files) → ONE self-contained `.html` — the shipping format.
  Parse the tree, render each file's literate nodes (prose narrates, code units embed), and
  bundle into a single hydrate-able page. The browser renders it everywhere.

  This is the first, dep-free pass: structurally-correct HTML from the parse. Full markdown
  rendering + island hydration + the compiled wasm/data artifacts join as `Nexus.Compile` lanes
  light up. (Thinned from the old `runtime/host/bundle.ex` — the new model needs far less.)
  """

  @doc "Weave a workbook folder into one self-contained HTML string."
  def weave(root) do
    root
    |> files()
    |> Enum.map(fn p -> {Path.relative_to(p, root), Nexus.Literate.parse(File.read!(p))} end)
    |> render()
  end

  defp files(root) do
    (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
    |> Enum.uniq()
  end

  defp render(pages) do
    body = Enum.map_join(pages, "\n", &page/1)

    """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><title>workbook</title>
    <style>#{css()}</style></head>
    <body>
    #{body}
    </body></html>
    """
  end

  defp page({name, nodes}) do
    ~s(<section class="file" data-file="#{name}">\n) <>
      Enum.map_join(nodes, "\n", &render_node/1) <> "\n</section>"
  end

  defp render_node(%{type: :heading, level: l, text: t}), do: "  <h#{l}>#{inline(t)}</h#{l}>"

  # A prose node can hold several lines — consecutive `- ` lines become a <ul>, the rest <p>.
  defp render_node(%{type: :prose, text: t}) do
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

  defp render_node(%{type: :decl, text: t}), do: ~s(  <pre class="decl">#{esc(t)}</pre>)

  defp render_node(%{type: :code, kind: k, name: n, body: b}) do
    ~s(  <figure class="unit" data-unit="#{k}:#{n}">) <>
      ~s(<figcaption><span class="kind">#{esc(k)}</span> #{esc(n)}</figcaption>) <>
      ~s(<pre>#{esc(b)}</pre></figure>)
  end

  defp render_node(_), do: ""

  # Minimal inline markdown: **bold**, *italic*, `code`, [text](url). Escape first, then format.
  defp inline(t) do
    t
    |> esc()
    |> String.replace(~r/\*\*(.+?)\*\*/, "<strong>\\1</strong>")
    |> String.replace(~r/(?<!\*)\*(?!\*)(.+?)\*(?!\*)/, "<em>\\1</em>")
    |> String.replace(~r/`(.+?)`/, "<code>\\1</code>")
    |> String.replace(~r/\[(.+?)\]\((https?:\/\/[^\s)]+)\)/, ~s(<a href="\\2">\\1</a>))
  end

  defp esc(s) do
    s |> to_string() |> String.replace("&", "&amp;") |> String.replace("<", "&lt;")
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
    """
  end
end

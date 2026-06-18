defmodule Nexus.Weave do
  @moduledoc """
  A workbook (a folder of `.work` files) → ONE self-contained `.html` — the shipping format.
  Parse the tree, render each file's literate nodes (prose narrates, code units embed), and
  bundle into a single hydrate-able page. The browser renders it everywhere.

  This is the first, dep-free pass: structurally-correct HTML from the parse. Full markdown
  rendering + island hydration + the compiled wasm/Ash artifacts join as `Nexus.Compile` lanes
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
    <html lang="en"><head><meta charset="utf-8"><title>workbook</title></head>
    <body>
    #{body}
    </body></html>
    """
  end

  defp page({name, nodes}) do
    ~s(<section data-file="#{name}">\n) <> Enum.map_join(nodes, "\n", &render_node/1) <> "\n</section>"
  end

  defp render_node(%{type: :heading, level: l, text: t}), do: "  <h#{l}>#{esc(t)}</h#{l}>"
  defp render_node(%{type: :prose, text: t}), do: "  <p>#{esc(t)}</p>"
  defp render_node(%{type: :decl, text: t}), do: ~s(  <pre class="decl">#{esc(t)}</pre>)
  defp render_node(%{type: :code, kind: k, name: n, body: b}), do: ~s(  <pre data-unit="#{k}:#{n}">#{esc(b)}</pre>)
  defp render_node(_), do: ""

  defp esc(s) do
    s |> to_string() |> String.replace("&", "&amp;") |> String.replace("<", "&lt;")
  end
end

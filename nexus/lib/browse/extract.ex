defmodule Nexus.Browse.Extract do
  @moduledoc """
  The cheap, no-wasm read rung — pure Elixir over Floki, runs entirely in the BEAM (isolated, no
  wasmtime). For the common research moves (read an SSR page, harvest links/citations, follow a
  sitemap) you need the DOM's text + link graph, not a CSS layout — so extracting the parsed HTML is
  ~50x cheaper than a Blitz render AND more faithful for server-rendered content (most of the web).

  `read/2` returns `%{title, text, markdown, links, thin?}`. `thin?` is the escalation signal: when
  the extracted text is too short to be real content (a client-rendered SPA shell), the caller bumps
  up to the Blitz wasm render (which can run the page's JS). So this is the bottom rung of the ladder:
  Floki extract → Blitz CSS render → Blitz+JS render — each ~10x the last, used only when needed.

  Massively parallel: it's plain BEAM work, so hundreds of agents can read concurrently without
  touching the bounded render lane at all.
  """

  # Structural/boilerplate tags whose text is noise for a reader; dropped before text/markdown.
  @drop ~w(script style noscript template svg head nav footer header aside form iframe button)a
  @thin_chars 200

  @type link :: %{href: String.t(), text: String.t()}
  @type t :: %{title: String.t(), text: String.t(), markdown: String.t(), links: [link], thin?: boolean}

  @doc "Parse `html` (base `url` for resolving relative links) into a reader's view. Never raises."
  @spec read(binary, String.t()) :: t
  def read(html, url) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        title = title(doc)
        links = links(doc, url)
        main = main_content(doc)
        md = main |> markdown() |> tidy()
        text = main |> Floki.text(sep: " ") |> tidy()
        %{title: title, text: text, markdown: md, links: links, thin?: String.length(text) < @thin_chars}

      _ ->
        %{title: "", text: "", markdown: "", links: [], thin?: true}
    end
  end

  # ── title ──────────────────────────────────────────────────────────────────────────────────────
  defp title(doc) do
    cond do
      (og = meta(doc, "og:title")) not in [nil, ""] -> og
      (t = doc |> Floki.find("title") |> Floki.text() |> tidy()) != "" -> t
      (h1 = doc |> Floki.find("h1") |> List.first()) -> h1 |> Floki.text() |> tidy()
      true -> ""
    end
  end

  defp meta(doc, prop) do
    doc
    |> Floki.find(~s(meta[property="#{prop}"], meta[name="#{prop}"]))
    |> Floki.attribute("content")
    |> List.first()
  end

  # ── links ──────────────────────────────────────────────────────────────────────────────────────
  # Every <a href> with anchor text, resolved absolute, deduped, on-page anchors/js dropped.
  defp links(doc, base) do
    doc
    |> Floki.find("a[href]")
    |> Enum.map(fn a ->
      %{href: a |> Floki.attribute("href") |> List.first() |> resolve(base), text: a |> Floki.text() |> tidy()}
    end)
    |> Enum.filter(fn %{href: h, text: t} -> usable_link?(h) and t != "" end)
    |> Enum.uniq_by(& &1.href)
  end

  defp usable_link?(nil), do: false
  defp usable_link?(h), do: String.starts_with?(h, "http")

  defp resolve(nil, _base), do: nil
  defp resolve(href, base) do
    cond do
      String.starts_with?(href, "http") -> href
      String.starts_with?(href, "#") -> nil
      String.starts_with?(href, "javascript:") or String.starts_with?(href, "mailto:") -> nil
      true -> base |> URI.merge(href) |> URI.to_string()
    end
  rescue
    _ -> nil
  end

  # ── main content (lightweight readability) ──────────────────────────────────────────────────────
  # Prefer the semantic main/article container; fall back to <body>. Then strip boilerplate tags.
  defp main_content(doc) do
    root =
      [Floki.find(doc, "main"), Floki.find(doc, "article"), Floki.find(doc, "body"), doc]
      |> Enum.find([], &(&1 != []))

    Floki.traverse_and_update(root, fn
      {tag, _, _} when tag in @drop -> nil
      node -> node
    end)
  end

  # ── HTML → Markdown ──────────────────────────────────────────────────────────────────────────────
  defp markdown(nodes) when is_list(nodes), do: Enum.map_join(nodes, "", &md_node/1)
  defp markdown(node), do: md_node(node)

  defp md_node(text) when is_binary(text), do: text |> String.replace(~r/\s+/, " ")

  defp md_node({"pre", _attrs, kids}), do: "\n\n```\n" <> tidy(Floki.text({"pre", [], kids})) <> "\n```\n\n"

  defp md_node({tag, _attrs, kids}) do
    inner = markdown(kids)

    case tag do
      h when h in ~w(h1 h2 h3 h4 h5 h6) ->
        "\n\n" <> String.duplicate("#", String.to_integer(String.last(h))) <> " " <> tidy(inner) <> "\n\n"

      b when b in ~w(p section div article main) -> "\n\n" <> inner <> "\n\n"
      "br" -> "\n"
      "li" -> "\n- " <> tidy(inner)
      s when s in ~w(strong b) -> "**" <> inner <> "**"
      e when e in ~w(em i) -> "_" <> inner <> "_"
      "code" -> "`" <> inner <> "`"
      l when l in ~w(ul ol) -> "\n" <> inner <> "\n"
      _ -> inner
    end
  end

  defp md_node(_), do: ""

  # collapse runs of blank lines / trailing whitespace
  defp tidy(s) do
    s
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end

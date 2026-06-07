defmodule Workbooks.Browse.Extract do
  @moduledoc """
  Turn fetched HTML into structured, agent-usable data — the second brick of the
  runtime's browse capability (after `Workbooks.Browse.Fetch`). In-process, pure
  stdlib: no parser dependency yet. This is intentionally a LIGHTWEIGHT extractor
  (regex + tag-strip) that covers the research-relevant surface — title, meta /
  OpenGraph, headings, links, and readable body text — and emits an org-mode
  document so a browse result drops straight into the workbook context repository.

  Robust DOM querying (CSS selectors, table extraction) is a later upgrade to
  Floki/mochiweb; the contract here (`page/2` → org string, plus the typed
  accessors) stays stable across that swap.
  """

  @type page :: %{
          url: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          headings: [String.t()],
          links: [%{href: String.t(), text: String.t()}],
          text: String.t()
        }

  @doc "Parse `html` (fetched from `url`) into a structured page map."
  @spec parse(String.t(), String.t()) :: page()
  def parse(html, url) do
    %{
      url: url,
      title: title(html),
      description: meta(html, "og:description") || meta_name(html, "description"),
      headings: headings(html),
      links: links(html, url),
      text: text(html)
    }
  end

  @doc "Render a parsed page (or raw html+url) as an org context-repository node."
  @spec page(String.t(), String.t()) :: String.t()
  def page(html, url), do: to_org(parse(html, url))

  @spec to_org(page()) :: String.t()
  def to_org(p) do
    host = URI.parse(p.url).host || p.url

    [
      "* #{p.title || host}                                                    :source:point:",
      "  :PROPERTIES:",
      "  :URL:    #{p.url}",
      "  :HOST:   #{host}",
      "  :END:",
      p.description && "  #{p.description}",
      p.headings != [] && "** outline",
      p.headings != [] && Enum.map_join(p.headings, "\n", &"   - #{&1}"),
      p.links != [] && "** links",
      p.links != [] && Enum.map_join(Enum.take(p.links, 40), "\n", &"   - [[#{&1.href}][#{&1.text}]]"),
      "** text",
      "   " <> (p.text |> String.slice(0, 4000) |> String.replace("\n", "\n   "))
    ]
    |> Enum.reject(&(&1 == nil or &1 == false))
    |> Enum.join("\n")
  end

  # ── field extractors ────────────────────────────────────────────────────────
  @spec title(String.t()) :: String.t() | nil
  def title(html) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/si, html) do
      [_, t] -> t |> decode() |> String.trim()
      _ -> meta(html, "og:title")
    end
  end

  @spec meta(String.t(), String.t()) :: String.t() | nil
  def meta(html, prop), do: meta_attr(html, "property", prop)
  @spec meta_name(String.t(), String.t()) :: String.t() | nil
  def meta_name(html, name), do: meta_attr(html, "name", name)

  defp meta_attr(html, attr, key) do
    re1 = ~r/<meta[^>]+#{attr}=["']#{Regex.escape(key)}["'][^>]+content=["']([^"']*)["']/i
    re2 = ~r/<meta[^>]+content=["']([^"']*)["'][^>]+#{attr}=["']#{Regex.escape(key)}["']/i
    case Regex.run(re1, html) || Regex.run(re2, html) do
      [_, v] -> decode(v)
      _ -> nil
    end
  end

  @spec headings(String.t()) :: [String.t()]
  def headings(html) do
    Regex.scan(~r/<h[1-3][^>]*>(.*?)<\/h[1-3]>/si, html)
    |> Enum.map(fn [_, h] -> h |> strip_tags() |> decode() |> String.trim() end)
    |> Enum.reject(&(&1 == "" or String.length(&1) < 2))
    |> Enum.uniq()
    |> Enum.take(60)
  end

  @spec links(String.t(), String.t()) :: [%{href: String.t(), text: String.t()}]
  def links(html, base) do
    Regex.scan(~r/<a[^>]+href=["']([^"'#]+)["'][^>]*>(.*?)<\/a>/si, html)
    |> Enum.map(fn [_, href, text] ->
      %{href: absolutize(base, href), text: text |> strip_tags() |> decode() |> String.trim()}
    end)
    |> Enum.reject(&(&1.text == "" or String.starts_with?(&1.href, "javascript:")))
    |> Enum.uniq_by(& &1.href)
  end

  @spec text(String.t()) :: String.t()
  def text(html) do
    html
    |> String.replace(~r/<script[\s\S]*?<\/script>/i, " ")
    |> String.replace(~r/<style[\s\S]*?<\/style>/i, " ")
    |> String.replace(~r/<!--[\s\S]*?-->/, " ")
    |> strip_tags()
    |> decode()
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n\s*\n\s*\n+/, "\n\n")
    |> String.trim()
  end

  @doc "Decode common HTML entities (named + numeric). Public for sibling modules."
  def decode_entities(s), do: decode(s)

  # ── helpers ─────────────────────────────────────────────────────────────────
  defp strip_tags(s), do: String.replace(s, ~r/<[^>]+>/, " ")

  defp decode(s) do
    s
    |> String.replace(~r/&#x([0-9a-fA-F]+);/, fn m ->
      [_, hex] = Regex.run(~r/&#x([0-9a-fA-F]+);/, m)
      <<String.to_integer(hex, 16)::utf8>>
    end)
    |> String.replace(~r/&#(\d+);/, fn m ->
      [_, dec] = Regex.run(~r/&#(\d+);/, m)
      <<String.to_integer(dec)::utf8>>
    end)
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&nbsp;", " ")
  end

  defp absolutize(base, href) do
    cond do
      String.starts_with?(href, "http") -> href
      String.starts_with?(href, "//") -> "https:" <> href
      true ->
        u = URI.parse(base)
        path = if String.starts_with?(href, "/"), do: href, else: "/" <> href
        "#{u.scheme}://#{u.host}#{path}"
    end
  end
end

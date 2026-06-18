defmodule Nexus.Browse.Page do
  @moduledoc """
  Parse a fetched page into the **actionable elements** an agent operates on — numbered links and
  forms (with their fields). This is the semantic-action substrate for Tier-1 computer-use: the
  agent reads the rendered text (via the Blitz renderer) and acts by element number (the
  browser-use / WebVoyager model). Structure lives in the (server-rendered) HTML, so it parses the
  HTML directly — no JS needed to enumerate links/forms.
  """

  @doc "Parse `html` (with `base_url` for resolving relative URLs) → `%{links, forms}`."
  def parse(html, base_url) do
    %{links: links(html, base_url), forms: forms(html, base_url)}
  end

  # ── links ──────────────────────────────────────────────────────────────────
  defp links(html, base_url) do
    Regex.scan(~r/<a\b[^>]*\bhref=["']([^"'#][^"']*)["'][^>]*>(.*?)<\/a>/is, html)
    |> Enum.map(fn [_, href, inner] -> %{text: text_of(inner), href: abs(href, base_url)} end)
    |> Enum.reject(&(&1.text == "" or String.starts_with?(&1.href, "javascript:")))
    |> Enum.uniq_by(& &1.href)
  end

  # ── forms ──────────────────────────────────────────────────────────────────
  defp forms(html, base_url) do
    Regex.scan(~r/<form\b([^>]*)>(.*?)<\/form>/is, html)
    |> Enum.map(fn [_, attrs, body] ->
      %{
        action: abs(attr(attrs, "action") || "", base_url),
        method: (attr(attrs, "method") || "get") |> String.downcase(),
        fields: fields(body)
      }
    end)
  end

  defp fields(body) do
    inputs =
      Regex.scan(~r/<(input|textarea|select)\b([^>]*)>/i, body)
      |> Enum.map(fn [_, tag, attrs] ->
        %{
          name: attr(attrs, "name"),
          type: (attr(attrs, "type") || default_type(tag)) |> String.downcase(),
          value: attr(attrs, "value") || ""
        }
      end)
      |> Enum.reject(&(&1.name in [nil, ""]))

    Enum.uniq_by(inputs, & &1.name)
  end

  defp default_type("textarea"), do: "textarea"
  defp default_type("select"), do: "select"
  defp default_type(_), do: "text"

  # ── helpers ──────────────────────────────────────────────────────────────────
  defp attr(attrs, name) do
    case Regex.run(~r/\b#{name}=["']([^"']*)["']/i, attrs) do
      [_, v] -> v
      _ -> nil
    end
  end

  defp text_of(inner) do
    inner |> String.replace(~r/<[^>]+>/, " ") |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  @doc "Resolve `href` against `base_url` (absolute URLs pass through)."
  def abs(href, base_url) do
    cond do
      href == "" -> base_url
      String.match?(href, ~r{^https?://}) -> href
      String.starts_with?(href, "//") -> scheme(base_url) <> ":" <> href
      String.starts_with?(href, "/") -> origin(base_url) <> href
      true -> dir(base_url) <> href
    end
  end

  defp scheme(url), do: if(String.starts_with?(url, "http://"), do: "http", else: "https")

  defp origin(url) do
    case Regex.run(~r{^(https?://[^/]+)}, url) do
      [_, o] -> o
      _ -> url
    end
  end

  defp dir(url), do: url |> String.replace(~r/[#?].*$/, "") |> String.replace(~r{[^/]*$}, "")
end

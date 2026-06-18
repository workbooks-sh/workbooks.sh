defmodule Nexus.Browse.Freeze do
  @moduledoc """
  "Freeze" a fetched page into a self-contained HTML string: inline external `<link rel=stylesheet>`
  as `<style>` (and, later, images as `data:` URIs) so the in-wasm Blitz renderer — which has no live
  network — can render it styled. Subresources are fetched HOST-side (brokered, SSRF-safe via
  `Nexus.Dock.fetch`); the render stays in the sandbox. Relative hrefs resolve against `base_url`.
  """

  @doc "Inline a page's external stylesheets. Returns self-contained HTML."
  def freeze(html, base_url) do
    Regex.replace(~r/<link\b[^>]*\brel=["']?stylesheet["']?[^>]*>/i, html, fn tag ->
      case href(tag) do
        nil -> tag
        href -> inline_css(href, base_url) || tag
      end
    end)
  end

  defp href(tag) do
    case Regex.run(~r/\bhref=["']([^"']+)["']/i, tag) do
      [_, h] -> h
      _ -> nil
    end
  end

  defp inline_css(href, base_url) do
    url = absolute(href, base_url)

    case Nexus.Dock.fetch(url) do
      "" -> nil
      css -> "<style>\n" <> css <> "\n</style>"
    end
  end

  @doc "Resolve `href` against `base_url` (absolute URLs pass through)."
  def absolute(href, base_url) do
    cond do
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
  defp dir(url), do: url |> String.replace(~r{[^/]*(\?.*)?$}, "")
end

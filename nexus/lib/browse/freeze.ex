defmodule Nexus.Browse.Freeze do
  @moduledoc """
  "Freeze" a fetched page into a self-contained HTML string: inline external `<link rel=stylesheet>`
  as `<style>` (and, later, images as `data:` URIs) so the in-wasm Blitz renderer — which has no live
  network — can render it styled. Subresources are fetched HOST-side (brokered, SSRF-safe via
  `Nexus.Dock.fetch`); the render stays in the sandbox. Relative hrefs resolve against `base_url`.
  """

  @doc """
  Make a page self-contained: inline external stylesheets (`<link rel=stylesheet>` → `<style>`) and,
  when `:scripts` is true, external scripts (`<script src>` → `<script>…</script>`) so the in-wasm JS
  layer can run them. Subresources are fetched HOST-side (brokered, SSRF-safe).
  """
  def freeze(html, base_url, opts \\ []) do
    html = inline_styles(html, base_url)
    if Keyword.get(opts, :scripts, false), do: inline_scripts(html, base_url), else: html
  end

  defp inline_styles(html, base_url) do
    Regex.replace(~r/<link\b[^>]*\brel=["']?stylesheet["']?[^>]*>/i, html, fn tag ->
      case href(tag) do
        nil -> tag
        href -> inline_css(href, base_url) || tag
      end
    end)
  end

  # Replace <script src="…"></script> with the fetched code inline so the in-wasm engine runs it.
  defp inline_scripts(html, base_url) do
    Regex.replace(~r/<script\b([^>]*\bsrc=["']([^"']+)["'][^>]*)>\s*<\/script>/i, html, fn whole, _attrs, src ->
      case Nexus.Dock.fetch(absolute(src, base_url)) do
        "" -> whole
        code -> "<script>" <> String.replace(code, "</script", "<\\/script") <> "</script>"
      end
    end)
  end

  @doc """
  Extract the JS bodies of every executable `<script>` in `html`, in document order — for the
  greenfield JS-DOM render, which runs them against a real DOM (`Nexus.JsDom`). Skips non-JS scripts
  (`type=application/json`, `type=…/ld+json`, importmap, etc.); plain and `type=module` scripts run.
  Run `freeze(html, base, scripts: true)` first so external `src` scripts are already inlined.
  """
  def script_bodies(html) do
    ~r/<script\b([^>]*)>(.*?)<\/script>/is
    |> Regex.scan(html)
    |> Enum.filter(fn [_, attrs, body] -> executable_script?(attrs) and String.trim(body) != "" end)
    |> Enum.map(fn [_, _, body] -> String.replace(body, "<\\/script", "</script") end)
  end

  defp executable_script?(attrs) do
    case Regex.run(~r/\btype=["']?([^"'\s>]+)/i, attrs) do
      nil -> true
      [_, t] -> String.downcase(t) in ["text/javascript", "application/javascript", "module", "text/babel"]
    end
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

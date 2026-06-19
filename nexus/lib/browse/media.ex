defmodule Nexus.Browse.Media do
  @moduledoc """
  EXPLORATION SPIKE — harvesting media files off a page via the browse/network layer.

  Two ideas, both leaning on the fact that ALL network egress goes through ONE brokered chokepoint
  (`Nexus.Dock.fetch/1`):

    1. `harvest/2` — parse a page (the same host-brokered fetch the scraper uses) for every media
       reference a real browser would request: `<img src/srcset/data-src>`, `<picture><source>`,
       `<video src/poster>`, `<audio>`, `og:image`/`twitter:image`, and CSS `url(...)` backgrounds.
       Resolve them to absolute URLs and bucket by kind. Reliable for static + CSS media.

    2. `fetch/1` — pull a media file's BYTES through the broker and sniff its real type from magic
       bytes (proving we can download the file, not just find the URL).

  This is the "HAR-lite" rung: it captures what's *declared* in the page. A FULL HAR (every resource
  a JS-driven page actually requests, incl. lazy-load/play-on-demand) needs a real JS browser with
  network interception — see the feasibility note in `docs/MEDIA-HARVEST-SPIKE.md`. Not wired into
  the agent swarm; this is a capability probe.
  """

  @doc "Harvest media references from `url`. Returns `{:ok, %{images, videos, audio, count}}`."
  def harvest(url, opts \\ []) do
    with {:ok, html} <- Nexus.Browse.fetch(url, opts),
         {:ok, doc} <- Floki.parse_document(html) do
      images = abs_all(img_srcs(doc) ++ css_urls(html), url)
      videos = abs_all(media_srcs(doc, "video") ++ Floki.attribute(Floki.find(doc, "video"), "poster"), url)
      audio = abs_all(media_srcs(doc, "audio"), url)

      {:ok, %{images: images, videos: videos, audio: audio, count: length(images) + length(videos) + length(audio)}}
    end
  end

  @doc "Download a media file through the broker; sniff its real type. `{:ok, %{type, bytes, data}}`."
  def fetch(url) do
    case Nexus.Browse.fetch(url) do
      {:ok, body} when is_binary(body) and byte_size(body) > 0 ->
        {:ok, %{type: sniff(body), bytes: byte_size(body), data: body}}

      {:ok, _} ->
        {:error, :empty}

      other ->
        other
    end
  end

  # ── media reference extraction ───────────────────────────────────────────────────────────────

  defp img_srcs(doc) do
    imgs = Floki.find(doc, "img")
    sources = Floki.find(doc, "picture source") ++ Floki.find(doc, "source")

    Floki.attribute(imgs, "src") ++
      Floki.attribute(imgs, "data-src") ++
      Floki.attribute(sources, "src") ++
      Enum.flat_map(imgs ++ sources, &srcset/1) ++
      meta(doc, "property", "og:image") ++
      meta(doc, "name", "twitter:image")
  end

  defp media_srcs(doc, tag) do
    Floki.attribute(Floki.find(doc, tag), "src") ++
      Floki.attribute(Floki.find(doc, "#{tag} source"), "src")
  end

  # `srcset="a.jpg 1x, b.jpg 2x"` → ["a.jpg", "b.jpg"] (the URL is the first token of each candidate)
  defp srcset(el) do
    case Floki.attribute([el], "srcset") do
      [set | _] -> set |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> String.split() |> List.first())) |> Enum.reject(&is_nil/1)
      _ -> []
    end
  end

  defp meta(doc, attr, val) do
    Floki.find(doc, "meta[#{attr}=\"#{val}\"]") |> Floki.attribute("content")
  end

  # CSS `url(...)` backgrounds from inline <style> + style="" attributes (crude but catches bg media).
  defp css_urls(html) do
    Regex.scan(~r/url\(\s*['"]?([^'")]+)['"]?\s*\)/i, html) |> Enum.map(fn [_, u] -> u end)
  end

  # ── url resolution + type sniffing ──────────────────────────────────────────────────────────

  defp abs_all(list, base) do
    list
    |> Enum.map(&absolutize(&1, base))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.reject(&String.starts_with?(&1, "data:"))
    |> Enum.uniq()
  end

  defp absolutize(ref, base) do
    ref = String.trim(ref)
    cond do
      ref == "" -> nil
      String.starts_with?(ref, "//") -> "https:" <> ref
      String.starts_with?(ref, "http") -> ref
      true -> base |> URI.merge(ref) |> URI.to_string()
    end
  rescue
    _ -> nil
  end

  # Real file type from magic bytes — independent of the URL's extension.
  defp sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  defp sniff(<<0x89, "PNG\r\n", 0x1A, 0x0A, _::binary>>), do: "image/png"
  defp sniff(<<"GIF8", _::binary>>), do: "image/gif"
  defp sniff(<<"RIFF", _::32, "WEBP", _::binary>>), do: "image/webp"
  defp sniff(<<"<svg", _::binary>>), do: "image/svg+xml"
  defp sniff(<<_::32, "ftyp", _::binary>>), do: "video/mp4"
  defp sniff(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: "video/webm"
  defp sniff(<<"OggS", _::binary>>), do: "audio/ogg"
  defp sniff(<<"ID3", _::binary>>), do: "audio/mpeg"
  defp sniff(_), do: "application/octet-stream"
end

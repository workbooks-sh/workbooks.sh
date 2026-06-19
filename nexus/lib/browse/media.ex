defmodule Nexus.Browse.Media do
  @moduledoc """
  Harvest + pull media files off a page — a `Nexus.Browse` capability (`:harvest`).

  Everything leans on the one brokered egress chokepoint, `Nexus.Dock.fetch/1`. Three rungs:

    * `harvest/2` — parse a page for every media reference a browser would request (`<img
      src/srcset/data-src>`, `<picture><source>`, `<video src/poster>`, `<audio>`, `og:image`/
      `twitter:image`, CSS `url(...)`), resolve to absolute URLs, bucket by kind, apply **filters**.
    * `get/2` — download one file's bytes through the broker, **cached** (so a repeat pull is free),
      with the real type sniffed from magic bytes.
    * `pull/2` — harvest → filter → download the matching objects (cached, concurrent), with
      post-download size filters. "Get me the real objects, just the ones I want."

  Filters (opts, all optional): `:kinds` (`[:image,:video,:audio]`), `:ext` (`["jpg","mp4",…]`),
  `:include`/`:exclude` (URL substrings), `:limit` (per kind). `pull` adds `:max` (total to
  download), `:concurrency`, `:min_bytes`/`:max_bytes`.

  LIMIT: this captures what the page *declares* (static + CSS). JS lazy-load / play-on-demand media
  needs a real JS browser with network interception (CDP/kernel.sh) — see docs/MEDIA-HARVEST-SPIKE.md.
  """
  @behaviour Nexus.Browse

  @impl true
  def capabilities, do: [:harvest]

  @impl true
  @doc "Harvest media references from `url`, filtered. `{:ok, %{images, videos, audio, count}}`."
  def harvest(url, opts \\ []) do
    kinds = opts[:kinds] || [:image, :video, :audio]

    with {:ok, html} <- Nexus.Browse.fetch(url, opts),
         {:ok, doc} <- Floki.parse_document(html) do
      # `deep: true` also inlines external stylesheets (freeze fetches them) so we catch CSS
      # background images declared in LINKED .css files — not just inline <style>/style="".
      css = css_urls(html) ++ if(opts[:deep], do: css_urls(safe_freeze(html, url)), else: [])

      images = if :image in kinds, do: filter(abs_all(img_srcs(doc) ++ css, url), opts), else: []
      videos = if :video in kinds, do: filter(abs_all(media_srcs(doc, "video") ++ Floki.attribute(Floki.find(doc, "video"), "poster"), url), opts), else: []
      audio = if :audio in kinds, do: filter(abs_all(media_srcs(doc, "audio"), url), opts), else: []

      {:ok, %{images: images, videos: videos, audio: audio, count: length(images) + length(videos) + length(audio)}}
    end
  end

  @doc """
  Render `url` while capturing the network → the HAR: every resource the render actually fetched
  (document, stylesheets, scripts) with type/bytes/timing. `{:ok, [%{url, type, bytes, ok, ms, at}]}`.
  The renderer fetches the document + CSS + JS (not media) — for media use `harvest/2`/`pull/2`.
  """
  def har(url, opts \\ []) do
    {_rendered, entries} = Nexus.Browse.Capture.with(fn -> Nexus.Browse.render(url, opts) end)
    {:ok, entries}
  end

  defp safe_freeze(html, url) do
    Nexus.Browse.Freeze.freeze(html, url)
  rescue
    _ -> ""
  end

  @doc "Download a media file through the broker (content-addressed cached). `{:ok, %{url, type, bytes, data}}`."
  def get(url, opts \\ []) do
    if opts[:cache] == false do
      download(url)
    else
      t = Nexus.Cache.default_tenant()

      case Nexus.Cache.get(t, "media", url) do
        # the cache is byte-oriented — we store the raw media bytes and rebuild the metadata here
        {:ok, body} when is_binary(body) ->
          {:ok, obj(url, body)}

        _ ->
          with {:ok, %{data: body} = o} <- download(url) do
            Nexus.Cache.put(t, "media", url, body)
            {:ok, o}
          end
      end
    end
  end

  @doc """
  Harvest + filter + download the matching media (cached, concurrent). `{:ok, [%{url,type,bytes,data}]}`.
  Honors all `harvest/2` filters plus `:max` (total objects, default 24), `:concurrency` (default 6),
  `:min_bytes`/`:max_bytes` (post-download size gate).
  """
  def pull(url, opts \\ []) do
    with {:ok, m} <- harvest(url, opts) do
      urls = (m.images ++ m.videos ++ m.audio) |> Enum.take(opts[:max] || 24)

      objs =
        urls
        |> Task.async_stream(&get(&1, opts), max_concurrency: opts[:concurrency] || 6, timeout: 30_000, on_timeout: :kill_task)
        |> Enum.flat_map(fn
          {:ok, {:ok, obj}} -> [obj]
          _ -> []
        end)
        |> Enum.filter(&size_ok(&1, opts))

      {:ok, objs}
    end
  end

  # ── download (the one place bytes are pulled) ─────────────────────────────────────────────────

  defp download(url) do
    case Nexus.Browse.fetch(url) do
      {:ok, body} when is_binary(body) and byte_size(body) > 0 -> {:ok, obj(url, body)}
      {:ok, _} -> {:error, :empty}
      other -> other
    end
  end

  defp obj(url, body), do: %{url: url, type: sniff(body), bytes: byte_size(body), data: body}

  # ── filters ──────────────────────────────────────────────────────────────────────────────────

  defp filter(list, opts) do
    inc = List.wrap(opts[:include])
    exc = List.wrap(opts[:exclude])

    list
    |> Enum.filter(&(ext_ok(&1, opts[:ext]) and inc_ok(&1, inc) and not has?(&1, exc)))
    |> maybe_take(opts[:limit])
  end

  defp ext_ok(_u, nil), do: true
  defp ext_ok(_u, []), do: true

  defp ext_ok(u, exts) do
    path = u |> String.split("?") |> hd() |> String.downcase()
    Enum.any?(exts, &String.ends_with?(path, "." <> (to_string(&1) |> String.trim_leading("."))))
  end

  defp inc_ok(_u, []), do: true
  defp inc_ok(u, subs), do: has?(u, subs)
  defp has?(u, subs), do: Enum.any?(subs, &String.contains?(String.downcase(u), String.downcase(to_string(&1))))

  defp maybe_take(list, nil), do: list
  defp maybe_take(list, n) when is_integer(n), do: Enum.take(list, n)

  defp size_ok(o, opts) do
    (opts[:min_bytes] == nil or o.bytes >= opts[:min_bytes]) and
      (opts[:max_bytes] == nil or o.bytes <= opts[:max_bytes])
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

  # `srcset="a.jpg 1x, b.jpg 2x"` → ["a.jpg", "b.jpg"] (URL is the first token of each candidate)
  defp srcset(el) do
    case Floki.attribute([el], "srcset") do
      [set | _] -> set |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> String.split() |> List.first())) |> Enum.reject(&is_nil/1)
      _ -> []
    end
  end

  defp meta(doc, attr, val), do: Floki.find(doc, "meta[#{attr}=\"#{val}\"]") |> Floki.attribute("content")

  # CSS `url(...)` backgrounds from inline <style> + style="" attributes.
  defp css_urls(html), do: Regex.scan(~r/url\(\s*['"]?([^'")]+)['"]?\s*\)/i, html) |> Enum.map(fn [_, u] -> u end)

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

  # Real file type from magic bytes (shared with the HAR layer).
  defp sniff(body), do: Nexus.Browse.Capture.classify(body)
end

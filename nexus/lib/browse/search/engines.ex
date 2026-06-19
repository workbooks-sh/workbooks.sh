defmodule Nexus.Browse.Search.Engines do
  @moduledoc """
  Per-engine HTML adapters for the keyless metasearch — each is `{build_url(query), parse(html)}`.

  An adapter parses the engine's **server-rendered** results page into
  `[%{title, url, snippet, rank}]` (rank = 1-based position). No JS is run — these engines emit real
  HTML, exactly the shape this tokenizer handles. Parsing is a single streaming pass over
  `:floki_mochi_html.tokens/1` (the same tokenizer `Nexus.Browse.Extract` uses), keyed on each
  engine's documented result-container / title / snippet classes (see `docs/SEARCH-ARCHITECTURE.md`
  §2 probe table). Selectors are class-substring matches so mild markup drift degrades gracefully.

  Shipped engines: **DuckDuckGo-HTML** and **Mojeek** (the two clean PRIMARY engines), plus
  **Startpage** and **Bing** as secondaries. URL canonicalization (incl. DDG's `uddg=` unwrap) is the
  ranker's job — adapters return URLs as-found.
  """

  @engines %{
    ddg: %{
      url: "https://html.duckduckgo.com/html/?q=",
      title_class: "result__a",
      snippet_class: "result__snippet"
    },
    mojeek: %{
      url: "https://www.mojeek.com/search?q=",
      title_class: "title",
      snippet_class: "s"
    },
    startpage: %{
      url: "https://www.startpage.com/sp/search?query=",
      title_class: "result-title",
      snippet_class: "description"
    },
    bing: %{
      url: "https://www.bing.com/search?q=",
      # Bing wraps each result title link in <h2><a>; the snippet lives in a <p>/caption div.
      title_class: nil,
      snippet_class: "b_caption"
    }
  }

  @doc "The list of supported keyless engine names."
  def names, do: Map.keys(@engines)

  @doc "Build the GET URL for `engine` and `query`."
  def build_url(engine, query) do
    %{url: base} = Map.fetch!(@engines, engine)
    base <> URI.encode_www_form(query)
  end

  @doc """
  Parse an engine's results-page `html` into `[%{title, url, snippet, rank}]`. Best-effort: returns
  `[]` on an unrecognized/blocked page rather than raising.
  """
  def parse(engine, html) when is_binary(html) do
    cfg = Map.fetch!(@engines, engine)
    results = scan(html, cfg)

    results
    |> Enum.with_index(1)
    |> Enum.map(fn {{title, url, snippet}, rank} ->
      %{title: title, url: url, snippet: snippet, rank: rank}
    end)
  end

  # ── streaming token scan ─────────────────────────────────────────────────────────────────────
  # One pass: collect every anchor whose class marks it a result title (or, for Bing, every <h2><a>),
  # plus the running text we accumulate as the snippet for the *current* result. We emit one tuple per
  # result anchor; the snippet is the text seen between this title anchor and the next.
  defp scan(html, cfg) do
    init = %{
      cfg: cfg,
      results: [],
      cur: nil,
      in_a: false,
      a_class: nil,
      href: nil,
      anchor: [],
      h2_depth: 0,
      snip: []
    }

    st =
      html
      |> tokens()
      |> Enum.reduce(init, &fold/2)
      |> flush()

    st.results |> Enum.reverse()
  end

  defp tokens(html) do
    :floki_mochi_html.tokens(html)
  rescue
    _ -> []
  end

  defp fold({:start_tag, name, attrs, _sc}, st) do
    n = down(name)
    class = attr(attrs, "class") || ""

    cond do
      n == "h2" -> %{st | h2_depth: st.h2_depth + 1}
      n == "a" -> open_a(st, attrs, class)
      true -> st
    end
  end

  defp fold({:end_tag, name}, st) do
    case down(name) do
      "h2" -> %{st | h2_depth: max(st.h2_depth - 1, 0)}
      "a" when st.in_a -> close_a(st)
      _ -> st
    end
  end

  defp fold({:data, data, _ws}, st), do: data(b(data), st)
  defp fold({:data, data}, st), do: data(b(data), st)
  defp fold(_other, st), do: st

  defp open_a(st, attrs, class) do
    title? = title_anchor?(st, class)

    if title? do
      # a new result begins → flush the snippet we've been collecting for the previous one
      st = flush(st)
      %{st | in_a: true, a_class: class, href: attr(attrs, "href"), anchor: [], snip: []}
    else
      st
    end
  end

  defp title_anchor?(%{cfg: %{title_class: tc}} = st, class) do
    cond do
      # Bing: no title class — a title link is any <a> inside an <h2>
      is_nil(tc) -> st.h2_depth > 0
      true -> class_has?(class, tc)
    end
  end

  defp close_a(st) do
    title = st.anchor |> Enum.reverse() |> IO.iodata_to_binary()
    %{st | in_a: false, cur: {title, st.href}, anchor: []}
  end

  defp data(d, st) do
    cond do
      st.in_a -> %{st | anchor: [d | st.anchor]}
      st.cur != nil -> %{st | snip: [d, ?\s | st.snip]}
      true -> st
    end
  end

  # commit the current result (title+url) with the accumulated snippet, then reset for the next.
  defp flush(%{cur: nil} = st), do: st

  defp flush(%{cur: {title, href}} = st) do
    snippet = st.snip |> Enum.reverse() |> IO.iodata_to_binary()
    result = {clean(title), href, clean(snippet)}

    keep? = href != nil and clean(title) != "" and String.starts_with?(href || "", "http") || wrapped?(href)

    results = if keep?, do: [result | st.results], else: st.results
    %{st | results: results, cur: nil, snip: []}
  end

  # DDG wraps real urls in a `//duckduckgo.com/l/?uddg=` redirector (no scheme) — accept it; the
  # ranker unwraps + canonicalizes.
  defp wrapped?(nil), do: false
  defp wrapped?(href), do: String.contains?(href, "uddg=") or String.starts_with?(href, "//")

  defp class_has?(class, want) do
    class
    |> String.split()
    |> Enum.any?(&(&1 == want or String.contains?(&1, want)))
  end

  defp clean(s), do: s |> String.replace(~r/\s+/, " ") |> String.trim()

  defp attr(attrs, key) do
    case List.keyfind(attrs, key, 0) do
      {_, v} ->
        b(v)

      _ ->
        case List.keyfind(attrs, String.to_charlist(key), 0) do
          {_, v} -> b(v)
          _ -> nil
        end
    end
  end

  defp down(x), do: x |> b() |> String.downcase()
  defp b(x) when is_binary(x), do: x
  defp b(x) when is_list(x), do: IO.iodata_to_binary(x)
  defp b(x) when is_atom(x), do: Atom.to_string(x)
  defp b(_), do: ""
end

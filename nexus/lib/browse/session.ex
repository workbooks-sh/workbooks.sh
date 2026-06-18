defmodule Nexus.Browse.Session do
  @moduledoc """
  A browsing session — the Tier-1 computer-use layer. An agent operates a site by *semantic action*:
  `navigate` a URL, read the rendered text, then act by element number — `click` a link, `fill` a
  form field, `submit` a form. State (current page, parsed links/forms, pending fills, cookies)
  persists across calls so multi-step flows (search, login, browse) work.

  This is the in-wasm tier: navigation = fetch (host-brokered, SSRF-safe, cookie jar) + render (Blitz,
  JS-or-SSR). It operates SSR sites + form flows fully in-sandbox; full heavy-SPA interaction is Tier 2.
  """

  @key {:nexus_browse, :session}

  defstruct url: nil, text: "", links: [], forms: [], fills: %{}, cookies: %{}

  @doc "The current session (a fresh one if none)."
  def current, do: :persistent_term.get(@key, %__MODULE__{})

  defp put(s), do: :persistent_term.put(@key, s)

  @doc "Reset the session (drops cookies + state)."
  def reset, do: put(%__MODULE__{})

  @doc "Navigate to `url` (GET) — fetch, render, parse actionables. Returns the new session."
  def navigate(url, s \\ nil) do
    s = s || current()

    case request(:get, url, "", s.cookies) do
      {:ok, html, cookies} ->
        text = render_text(html, url)
        %{links: links, forms: forms} = Nexus.Browse.Page.parse(html, url)
        new = %__MODULE__{url: url, text: text, links: links, forms: forms, fills: %{}, cookies: cookies}
        put(new)
        {:ok, new}

      {:error, _} = err ->
        err
    end
  end

  @doc "Click a link by 1-based index or by (case-insensitive substring of) its text."
  def click(target, s \\ nil) do
    s = s || current()

    case find_link(s.links, target) do
      nil -> {:error, {:no_such_link, target}}
      %{href: href} -> navigate(href, s)
    end
  end

  @doc "Set a form field's value (by field name) for the next submit."
  def fill(field, value, s \\ nil) do
    s = s || current()
    new = %{s | fills: Map.put(s.fills, field, value)}
    put(new)
    {:ok, new}
  end

  @doc "Submit a form (1-based index, default 1) using its fields + any `fill`ed values."
  def submit(form_index \\ 1, s \\ nil) do
    s = s || current()

    case Enum.at(s.forms, form_index - 1) do
      nil ->
        {:error, {:no_such_form, form_index}}

      form ->
        params = build_params(form, s.fills)

        case form.method do
          "post" -> post_submit(form.action, params, s)
          _ -> navigate(with_query(form.action, params), s)
        end
    end
  end

  defp post_submit(action, params, s) do
    body = URI.encode_query(params)

    case request(:post, action, body, s.cookies) do
      {:ok, html, cookies} ->
        text = render_text(html, action)
        %{links: links, forms: forms} = Nexus.Browse.Page.parse(html, action)
        new = %__MODULE__{url: action, text: text, links: links, forms: forms, cookies: cookies}
        put(new)
        {:ok, new}

      err ->
        err
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────
  defp render_text(html, url) do
    case Nexus.Browse.Blitz.render_html(html, url) do
      {:ok, t} -> t
      _ -> ""
    end
  end

  defp find_link(links, n) when is_integer(n), do: Enum.at(links, n - 1)

  defp find_link(links, text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} ->
        Enum.at(links, n - 1)

      _ ->
        down = String.downcase(text)
        Enum.find(links, &String.contains?(String.downcase(&1.text), down))
    end
  end

  # form params: declared field values overlaid with the agent's fills.
  defp build_params(form, fills) do
    base = for f <- form.fields, f.name not in [nil, ""], into: %{}, do: {f.name, f.value}
    Map.merge(base, fills)
  end

  defp with_query(action, params) when map_size(params) == 0, do: action
  defp with_query(action, params) do
    sep = if String.contains?(action, "?"), do: "&", else: "?"
    action <> sep <> URI.encode_query(params)
  end

  # ── HTTP (GET/POST, cookie jar, SSRF-safe) ──────────────────────────────────
  defp request(method, url, body, cookies) do
    if allowed?(url) do
      :inets.start()
      :ssl.start()

      ssl_opts = [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]

      cookie_hdr = cookie_header(cookies)
      ua = ~c"Mozilla/5.0 (nexus-browse)"
      headers = [{~c"user-agent", ua}, {~c"accept", ~c"text/html"} | cookie_hdr]
      http_opts = [ssl: ssl_opts, timeout: 30_000, autoredirect: true]

      req =
        case method do
          :get -> {String.to_charlist(url), headers}
          :post -> {String.to_charlist(url), headers, ~c"application/x-www-form-urlencoded", body}
        end

      case :httpc.request(method, req, http_opts, body_format: :binary) do
        {:ok, {{_, status, _}, resp_headers, resp}} when status in 200..399 ->
          {:ok, resp, merge_cookies(cookies, resp_headers)}

        {:ok, {{_, status, _}, _, _}} ->
          {:error, {:http_status, status}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :blocked}
    end
  end

  defp cookie_header(cookies) when map_size(cookies) == 0, do: []
  defp cookie_header(cookies) do
    v = Enum.map_join(cookies, "; ", fn {k, val} -> "#{k}=#{val}" end)
    [{~c"cookie", String.to_charlist(v)}]
  end

  defp merge_cookies(cookies, resp_headers) do
    resp_headers
    |> Enum.filter(fn {k, _} -> String.downcase(to_string(k)) == "set-cookie" end)
    |> Enum.reduce(cookies, fn {_, v}, acc ->
      case to_string(v) |> String.split(";", parts: 2) |> List.first() |> String.split("=", parts: 2) do
        [name, val] -> Map.put(acc, String.trim(name), String.trim(val))
        _ -> acc
      end
    end)
  end

  # SSRF guard (mirror Nexus.Dock): block non-http(s) + loopback/private hosts.
  defp allowed?(url) do
    uri = URI.parse(url)
    host = uri.host || ""

    uri.scheme in ["http", "https"] and not private?(host)
  end

  defp private?(h) do
    h in ["localhost", "127.0.0.1", "0.0.0.0", "::1", ""] or
      String.starts_with?(h, "127.") or String.starts_with?(h, "10.") or
      String.starts_with?(h, "192.168.") or String.starts_with?(h, "169.254.") or
      String.match?(h, ~r/^172\.(1[6-9]|2\d|3[01])\./)
  end
end

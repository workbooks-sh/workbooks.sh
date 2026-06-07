defmodule Workbooks.Browse.Fetch do
  @moduledoc """
  Native, in-process HTTPS GET for the runtime's browse capability — no Rust, no
  port, no sidecar. Built on Erlang's pure-Erlang `:ssl` stack, which lets us
  SHAPE the TLS handshake (version + cipher ordering) per a named profile so a
  fetch can present a browser-like fingerprint. This is the `gather` primitive
  `Workbooks.Browse` is built on (Extract + Crawl sit on top).

  A spike proved the control: the same endpoint completes under both a default
  TLS 1.3 handshake and a forced TLS 1.2 + reordered-cipher handshake — i.e. the
  ClientHello is ours to configure from pure Elixir. Byte-exact JA3/JA4 matching
  (extension order + GREASE) is later work in a custom ClientHello encoder; the
  primitive here is the foundation.

  Returns `{:ok, %{status, headers, body}}` or `{:error, reason}`. Follows up to
  `:max_redirects` redirects. `:profile` selects the handshake shape.
  """

  @type result :: {:ok, %{status: pos_integer(), headers: list(), body: binary()}} | {:error, term()}

  @default_max_redirects 5
  @timeout 20_000

  @doc """
  GET `url`. Options: `:profile` (`:default` | `:chrome` | `:safari`),
  `:headers` (list of `{key, val}` strings), `:max_redirects`.
  """
  @spec get(String.t(), keyword()) :: result()
  def get(url, opts \\ []) do
    ensure_started()
    profile = Keyword.get(opts, :profile, :chrome)
    redirects = Keyword.get(opts, :max_redirects, @default_max_redirects)
    headers = Keyword.get(opts, :headers, default_headers(profile))
    request(url, profile, headers, redirects)
  end

  defp request(_url, _profile, _headers, redirects) when redirects < 0,
    do: {:error, :too_many_redirects}

  defp request(url, profile, headers, redirects) do
    http_opts = [ssl: ssl_opts(profile), timeout: @timeout, connect_timeout: @timeout, autoredirect: false]
    req = {String.to_charlist(url), Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}

    case :httpc.request(:get, req, http_opts, body_format: :binary) do
      {:ok, {{_, status, _}, hdrs, body}} when status in 300..399 ->
        case location(hdrs) do
          nil -> {:ok, %{status: status, headers: hdrs, body: body}}
          loc -> request(absolute(url, loc), profile, headers, redirects - 1)
        end

      {:ok, {{_, status, _}, hdrs, body}} ->
        {:ok, %{status: status, headers: hdrs, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── TLS handshake profiles ──────────────────────────────────────────────────
  # The pure-Erlang :ssl stack honours these. Profiles approximate a browser's
  # version + cipher posture today; an exact-fingerprint encoder lands later.
  defp ssl_opts(:default), do: [verify: :verify_none]

  defp ssl_opts(profile) when profile in [:chrome, :safari] do
    [
      verify: :verify_none,
      versions: [:"tlsv1.3", :"tlsv1.2"],
      ciphers: browser_ciphers(),
      eccs: [:x25519, :secp256r1, :secp384r1],
      signature_algs_cert: :ssl.signature_algs(:default, :"tlsv1.3")
    ]
  end

  # A browser-leaning cipher posture (TLS 1.3 AEAD suites first, then common 1.2).
  defp browser_ciphers do
    all = :ssl.cipher_suites(:all, :"tlsv1.3") ++ :ssl.cipher_suites(:all, :"tlsv1.2")
    Enum.uniq(all)
  end

  defp default_headers(profile) do
    [
      {"user-agent", user_agent(profile)},
      {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
      {"accept-language", "en-US,en;q=0.9"}
    ]
  end

  defp user_agent(:safari),
    do: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

  defp user_agent(_),
    do: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

  # ── helpers ─────────────────────────────────────────────────────────────────
  defp location(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == "location", do: to_string(v), else: nil
    end)
  end

  defp absolute(base, loc) do
    cond do
      String.starts_with?(loc, "http") -> loc
      String.starts_with?(loc, "//") -> "https:" <> loc
      true ->
        uri = URI.parse(base)
        path = if String.starts_with?(loc, "/"), do: loc, else: "/" <> loc
        "#{uri.scheme}://#{uri.host}#{path}"
    end
  end

  defp ensure_started do
    :inets.start()
    :ssl.start()
    :ok
  end
end

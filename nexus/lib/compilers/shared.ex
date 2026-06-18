defmodule Nexus.Compilers.Shared do
  @moduledoc """
  Cross-cutting helpers shared by every compiler lane (Native/Rust/Js) and the
  `Nexus.Compilers` facade: discovery root, the manifest reader, the wasmtime
  sandbox executor, a verified-TLS HTTPS GET, and shell-escaping. Extracted from the
  former compilers.ex god-file so each lane module depends on ONE home for these.
  """

  # clang/lld (YoWASP LLVM-for-wasi) link paths inside the mounted sysroot (/usr).
  @clang_lib_rt "/usr/lib/wasm32-unknown-wasip1"
  @clang_lib_c "/usr/lib/wasm32-wasip1"

  def clang_lib_rt, do: @clang_lib_rt
  def clang_lib_c, do: @clang_lib_c

  @doc "Discovery root for compilers/<lang>/."
  def default_root do
    Enum.find(["compilers", "../runtime/compilers", "runtime/compilers", Path.expand("../runtime/compilers", File.cwd!())], &File.dir?/1) ||
      "compilers"
  end

  @doc "Run `wasmtime run <args>` and return its combined output (the sandbox executor)."
  def wasmtime(args) do
    {out, _} = System.cmd("wasmtime", ["run"] ++ [] ++ args, stderr_to_stdout: true)
    out
  end

  @doc """
  Pure-Erlang HTTPS GET (:httpc) with VERIFIED TLS via the OS trust store — replaces the curl
  binary in the compile path (wb-ova). Follows redirects (static.crates.io). Returns {:ok, body}.
  """
  def http_get(url) do
    :inets.start()
    :ssl.start()

    ssl_opts = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      depth: 3
    ]

    req = {String.to_charlist(url), browser_headers()}
    http_opts = [ssl: ssl_opts, timeout: 30_000, connect_timeout: 15_000, autoredirect: true]

    case :httpc.request(:get, req, http_opts, body_format: :binary) do
      {:ok, {{_v, 200, _}, headers, body}} -> {:ok, decode_body(headers, body)}
      {:ok, {{_v, code, _}, _headers, _body}} -> {:error, {:http_status, code}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A realistic Chrome header set. The single highest-leverage anti-block fix: an empty header list
  # sends no User-Agent, which many sites (Wikipedia, anything CDN-fronted) answer with a 403. This
  # does NOT forge the TLS fingerprint (Erlang :ssl can't) — but a believable UA + Accept* + client
  # hints clears normal and baseline-Cloudflare sites, ~90% of real-world reach. (curl-impersonate is
  # the host-brokered escalation for the aggressive JA3/JA4 tier.)
  @chrome_ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
  defp browser_headers do
    [
      {~c"user-agent", String.to_charlist(@chrome_ua)},
      {~c"accept", ~c"text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"},
      {~c"accept-language", ~c"en-US,en;q=0.9"},
      # Only advertise encodings we can actually decode (:zlib handles gzip + deflate; not brotli).
      {~c"accept-encoding", ~c"gzip, deflate"},
      {~c"sec-ch-ua", ~c"\"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\""},
      {~c"sec-ch-ua-mobile", ~c"?0"},
      {~c"sec-ch-ua-platform", ~c"\"macOS\""},
      {~c"sec-fetch-dest", ~c"document"},
      {~c"sec-fetch-mode", ~c"navigate"},
      {~c"sec-fetch-site", ~c"none"},
      {~c"sec-fetch-user", ~c"?1"},
      {~c"upgrade-insecure-requests", ~c"1"}
    ]
  end

  # :httpc does not auto-decompress; we asked for gzip/deflate, so undo it when present.
  defp decode_body(headers, body) do
    enc = headers |> Enum.find_value(fn {k, v} -> if to_string(k) |> String.downcase() == "content-encoding", do: to_string(v) |> String.downcase() end)

    try do
      case enc do
        "gzip" -> :zlib.gunzip(body)
        "deflate" -> :zlib.uncompress(body)
        _ -> body
      end
    rescue
      _ -> body
    end
  end

  @doc "Single-quote escape a path for a `sh -c` command line."
  def esc(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"
end

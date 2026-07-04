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
    Enum.find(["compilers", Path.expand("compilers", File.cwd!())], &File.dir?/1) ||
      "compilers"
  end

  @doc """
  Run `wasmtime run <args>` and return its combined output (the sandbox executor). The subprocess env
  is SCRUBBED (wb-od4a) so a malicious source compiled here can't read injected secrets (WB_*,
  OPENROUTER_API_KEY) from the wasmtime host process — guest env is the explicit `--env` flags only.
  """
  def wasmtime(args) do
    # wb-3f42: cap the compiler's linear memory so a malicious/runaway source can't grow it until the
    # host OOMs. Generous (compiles need GBs) but bounded; epoch-free so it stays AOT-`.cwasm`-compatible.
    mem = Nexus.Config.sandbox_compile_memory_mb() * 1024 * 1024
    caps = ["-W", "max-memory-size=#{mem}", "-W", "trap-on-grow-failure=y"]

    {out, _} =
      System.cmd("wasmtime", ["run"] ++ caps ++ Nexus.Wasm.Aot.resolve_args(args),
        env: Nexus.Subprocess.scrubbed_env(),
        stderr_to_stdout: true
      )

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

    build_req = fn _m, u -> {String.to_charlist(u), browser_headers()} end
    http_opts = [ssl: ssl_opts, timeout: 30_000, connect_timeout: 15_000]

    # SSRF: re-guard every redirect hop (wb-6vb9) — this is a guest-influenced fetch.
    case Nexus.Net.Ssrf.request(:get, url, build_req, http_opts) do
      {:ok, {{_v, 200, _}, headers, body}} ->
        decoded = decode_body(headers, body)
        # Fast path unchanged, UNLESS the 200 is a CF-challenge/anti-bot interstitial (tiny/challenge
        # body) — then escalate to the impersonate fallback just like a 403.
        if should_escalate?(200, decoded), do: maybe_impersonate(url, {:ok, decoded}), else: {:ok, decoded}

      {:ok, {{_v, code, _}, headers, body}} ->
        # 403 / challenge: Erlang :ssl can't forge a Chrome TLS (JA3/JA4) fingerprint, so the
        # aggressive anti-bot tier blocks us. Escalate to host-brokered curl-impersonate (real
        # BoringSSL Chrome fingerprint) if it's discoverable; otherwise degrade to the original error.
        orig = {:error, {:http_status, code}}
        if should_escalate?(code, decode_body(headers, body)), do: maybe_impersonate(url, orig), else: orig

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The escalation DECISION (pure, unit-tested): retry via curl-impersonate when :httpc got a 403 /
  # challenge status, or a 200 whose body is suspiciously tiny / a known challenge interstitial. A
  # real, populated 200 returns false (fast path stays fast).
  @challenge_statuses [401, 403, 406, 429, 503]
  @tiny_body_bytes 512
  @doc false
  def should_escalate?(status, body) when is_binary(body) do
    cond do
      status in @challenge_statuses -> true
      status == 200 and challenge_body?(body) -> true
      true -> false
    end
  end

  def should_escalate?(status, _body), do: status in @challenge_statuses

  defp challenge_body?(body) do
    byte_size(body) < @tiny_body_bytes or
      (body
       |> binary_part(0, min(byte_size(body), 4096))
       |> String.downcase()) =~
        ~r/(just a moment|attention required|cf-challenge|_cf_chl_opt|challenge-platform|please enable (javascript|cookies)|px-captcha|perimeterx|access denied)/
  end

  # Host-brokered curl-impersonate fallback. SSRF-guarded (reuse the Dock gate — never an unguarded
  # egress). Degrades to `orig` if the gate rejects, the binary is absent, or the retry isn't a real 200.
  defp maybe_impersonate(url, orig) do
    cond do
      not Nexus.Dock.net_allowed?(url) -> orig
      bin = curl_impersonate_bin() -> impersonate_get(bin, url, orig)
      true -> orig
    end
  end

  # Discover a curl-impersonate binary: a configured `:nexus, :curl_impersonate` path, else a
  # `curl_chrome*` / `curl-impersonate*` wrapper on PATH. nil if none — caller degrades gracefully.
  @doc false
  def curl_impersonate_bin do
    configured = Application.get_env(:nexus, :curl_impersonate)

    cond do
      is_binary(configured) and File.exists?(configured) -> configured
      true -> Enum.find_value(~w(curl_chrome131 curl_chrome120 curl_chrome116 curl_chrome110 curl-impersonate-chrome curl-impersonate), &System.find_executable/1)
    end
  end

  defp impersonate_get(bin, url, orig) do
    # `curl_chrome*` wrappers preset the Chrome JA3/JA4 + h2 fingerprint; we add gzip decode, a timeout,
    # and fail-on-non-2xx. We DO NOT follow redirects (`--max-redirs 0`, no `-L`): curl following a 3xx
    # in-binary would bypass the per-hop SSRF re-guard the Elixir path enforces, letting a public host
    # redirect us to 169.254.169.254 / an internal IP (red-team wb-jsng). A legit redirect is re-fetched
    # by the SSRF-guarded Elixir request path, not here.
    args = ["-sS", "--max-redirs", "0", "--compressed", "--max-time", "30", "--fail", url]

    case System.cmd(bin, args, stderr_to_stdout: false) do
      {body, 0} when byte_size(body) > 0 ->
        if should_escalate?(200, body), do: orig, else: {:ok, body}

      _ ->
        orig
    end
  rescue
    _ -> orig
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

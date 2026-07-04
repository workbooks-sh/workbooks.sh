defmodule Nexus.FishAudio do
  @moduledoc """
  A thin client for the Fish Audio speech API — the TTS (and fallback ASR) provider behind the
  in-app voice pipeline (epic wb-q29ga): local Moonshine/Silero STT → the real agent brain →
  sentence-chunked Fish TTS streamed back to the desktop player.

  Mirrors `Nexus.Telnyx`/`Nexus.Polar` (TLS verify_peer + pinned SNI, token never in
  `build_request`, fixed host, capped body, injectable `:http` seam). The cloud layer wires the
  routes (`/cloud/voice/tts` proxy); this module stays a neutral, no-op-safe mechanism.

  AUTH: a `Bearer` token from `FISH_API_KEY`, read through `Nexus.Secrets` — the ONE audited secret
  seam. The key is a HOST credential: it never reaches a renderer/client (unlike the legacy Gemini
  key-in-WS-URL pattern this pipeline retires), never appears in a log line, an error tuple, or any
  returned value. It lives only in the `authorization` header handed straight to `:httpc` (added in
  `do_request/5` / the stream request, never in `build_request/4`).

  BILLING NOTE: Fish bills TTS from a dedicated "API credit" wallet, managed separately from
  platform credit (their 402 says so verbatim) — fund it at fish.audio/app/developers.

  ENDPOINTS — confirmed against api.fish.audio:
    * synthesize speech    — POST /v1/tts   (JSON body; model picked via the `model` HTTP header)
    * transcribe (ASR)     — POST /v1/asr   (fallback cloud STT; live-verified in wb-q29ga.7)
    * api credit balance   — GET  /wallet/self/api-credit (the configured?/funded? probe)

  STREAMING: `tts_stream/3` uses `:httpc`'s async `stream: :self` delivery — audio chunks invoke
  `on_chunk` as they arrive off the wire, so the caller (the `/cloud/voice/tts` proxy) can forward
  bytes with no full-response buffering. Plain `tts/2` buffers and returns the whole clip.
  """

  @api_host "https://api.fish.audio"
  @sni ~c"api.fish.audio"

  @doc "The fixed Fish Audio API host (never caller-supplied)."
  def api_host, do: @api_host

  @doc "True when a Fish Audio API key is configured (the voice pipeline is live on this nexus)."
  def configured?, do: is_binary(Nexus.Secrets.get("FISH_API_KEY"))

  # ── TTS ─────────────────────────────────────────────────────────────────────────

  @doc """
  Synthesize `text` and return `{:ok, audio_binary}` (whole clip, buffered). `opts`:
  `:model` (HTTP header — "s1" default; "s2"/"s2.1-pro"/"speech-1.5"), `:format` ("mp3" default |
  "wav" | "pcm" | "opus"), `:reference_id` (a Fish voice/model id — the autopoet's voice),
  `:sample_rate`, `:latency` ("balanced" default — Fish's low-latency mode), `:chunk_length`.
  `{:error, :not_configured}` with no key; `{:error, :missing_text}` on blank text.
  """
  def tts(text, opts \\ []) do
    opts = Map.new(opts)

    cond do
      not (configured?() or is_binary(opts[:token])) -> {:error, :not_configured}
      not is_binary(text) or String.trim(text) == "" -> {:error, :missing_text}
      true -> request(:post, ["v1", "tts"], tts_body(text, opts), tts_headers(opts) ++ pass_opts(opts))
    end
  end

  @doc """
  Synthesize `text`, invoking `on_chunk.(binary)` for every audio chunk AS IT ARRIVES (no full
  buffering) — the real-time path behind `/cloud/voice/tts`. Returns `{:ok, total_bytes}` once the
  stream completes, `{:error, reason}` otherwise. Same opts as `tts/2` plus `:recv_timeout` (ms,
  default 30_000 per chunk gap). PCM/opus formats suit the desktop `PcmPlayer` best.
  """
  def tts_stream(text, on_chunk, opts \\ []) when is_function(on_chunk, 1) do
    opts = Map.new(opts)

    cond do
      not (configured?() or is_binary(opts[:token])) -> {:error, :not_configured}
      not is_binary(text) or String.trim(text) == "" -> {:error, :missing_text}
      is_function(opts[:http_stream], 2) -> opts[:http_stream].(tts_body(text, opts), on_chunk)
      true -> do_stream(tts_body(text, opts), tts_headers(opts), on_chunk, opts)
    end
  end

  defp tts_body(text, opts) do
    %{"text" => text, "format" => opts[:format] || "mp3", "latency" => opts[:latency] || "balanced"}
    |> put_some("reference_id", opts[:reference_id])
    |> put_some("sample_rate", opts[:sample_rate])
    |> put_some("chunk_length", opts[:chunk_length])
  end

  # The synthesis model rides an HTTP header (Fish's convention), not the body.
  defp tts_headers(opts), do: [headers: [{"model", to_string(opts[:model] || "s1")}]]

  # ── ASR (cloud STT fallback — wb-q29ga.7) ───────────────────────────────────────

  @doc """
  Transcribe `audio` bytes → `{:ok, %{"text" => ...}}`. JSON-shaped (`audio` base64, optional
  `:language`, `:ignore_timestamps`); live-verified against the funded account in wb-q29ga.7 —
  the desktop path uses on-device Moonshine and never hits this.
  """
  def asr(audio, opts \\ []) when is_binary(audio) do
    opts = Map.new(opts)

    cond do
      not (configured?() or is_binary(opts[:token])) -> {:error, :not_configured}
      audio == "" -> {:error, :missing_audio}
      true ->
        body =
          %{"audio" => Base.encode64(audio)}
          |> put_some("language", opts[:language])
          |> put_some("ignore_timestamps", opts[:ignore_timestamps])

        request(:post, ["v1", "asr"], body, pass_opts(opts))
    end
  end

  @doc "The API-credit wallet balance — the funded? probe. GET /wallet/self/api-credit."
  def api_credit(opts \\ []) do
    opts = Map.new(opts)

    if configured?() or is_binary(opts[:token]) do
      request(:get, ["wallet", "self", "api-credit"], nil, pass_opts(opts))
    else
      {:error, :not_configured}
    end
  end

  # Forward only the injectable seams (used by tests) into the request layer.
  defp pass_opts(opts) when is_map(opts),
    do: Enum.filter([:http, :token], &Map.has_key?(opts, &1)) |> Enum.map(&{&1, opts[&1]})

  defp put_some(map, _k, nil), do: map
  defp put_some(map, _k, ""), do: map
  defp put_some(map, k, v), do: Map.put(map, k, v)

  # ── Pure request construction (network-free; unit-testable) ─────────────────────

  @doc """
  Build the `{method, url, headers, body}` 4-tuple WITHOUT performing it. Pure and network-free.
  The `Authorization: Bearer <token>` header is DELIBERATELY NOT added here — the token is injected
  only in the private HTTP layer, so it never appears in this pure return value, a log, or a test
  fixture. `opts[:headers]` adds extra non-secret headers (the `model` selector).
  """
  def build_request(method, segments, body, opts \\ []) when is_list(segments) do
    url = @api_host <> "/" <> Enum.join(segments, "/")

    headers =
      [{"accept", "*/*"}] ++
        Keyword.get(opts, :headers, []) ++
        if(is_map(body), do: [{"content-type", "application/json"}], else: [])

    encoded = if is_map(body), do: Jason.encode!(body), else: ""
    {method, url, headers, encoded}
  end

  @doc false
  # Pinned TLS http-options (same verify_peer pattern as `Nexus.Telnyx`/`Nexus.Polar`). Exposed so
  # the test can regression-lock verify_peer + non-empty cacerts + SNI.
  def http_options do
    [
      timeout: 60_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: @sni,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end

  # ── Internal: construct + dispatch + map ────────────────────────────────────────

  # Cap buffered response reads so a hostile/oversized response can't exhaust memory. (Streaming
  # chunks are forwarded as they arrive and never accumulated here.)
  @max_body_bytes 32 * 1024 * 1024

  defp request(method, segments, body, opts) do
    {method, url, headers, encoded} = build_request(method, segments, body, opts)
    token = Keyword.get(opts, :token) || Nexus.Secrets.get("FISH_API_KEY") || ""
    http = Keyword.get(opts, :http, &do_request(&1, &2, &3, &4, token))

    case http.(method, url, headers, encoded) do
      {:ok, {status, resp}} when status in 200..299 -> {:ok, decode(resp)}
      {:ok, {status, resp}} -> {:error, {status, decode(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Real HTTP via :httpc. The `Authorization: Bearer <token>` header is added HERE — never by
  # `build_request`. TLS is verified (verify_peer + pinned SNI). Never logs headers.
  defp do_request(method, url, headers, body, token) do
    :inets.start()
    :ssl.start()

    headers = [{"authorization", "Bearer " <> token} | headers]
    http_headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    req =
      if method in [:post, :put, :patch, :delete] and body != "" do
        {to_charlist(url), http_headers, ~c"application/json", body}
      else
        {to_charlist(url), http_headers}
      end

    case :httpc.request(method, req, http_options(), body_format: :binary) do
      {:ok, {{_, code, _}, _resp_headers, resp}} -> {:ok, {code, cap_body(resp)}}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  # Async streaming request: chunks are delivered to THIS process's mailbox and forwarded to
  # `on_chunk` as they land. A non-2xx status is collected and returned as a normal error tuple.
  defp do_stream(body, extra, on_chunk, opts) do
    {method, url, headers, encoded} = build_request(:post, ["v1", "tts"], body, extra)
    token = Map.get(opts, :token) || Nexus.Secrets.get("FISH_API_KEY") || ""
    recv_timeout = Map.get(opts, :recv_timeout) || 30_000

    :inets.start()
    :ssl.start()

    http_headers =
      [{~c"authorization", to_charlist("Bearer " <> token)}] ++
        Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    req = {to_charlist(url), http_headers, ~c"application/json", encoded}

    case :httpc.request(method, req, http_options(), sync: false, stream: :self, body_format: :binary) do
      {:error, e} -> {:error, inspect(e)}
      {:ok, rid} -> stream_loop(rid, on_chunk, recv_timeout, nil, 0, [])
    end
  end

  # status=nil until the first head arrives; on a non-2xx we swallow chunks into `err_acc` and
  # surface {:error, {status, body}} at stream end — same error shape as the buffered path.
  defp stream_loop(rid, on_chunk, timeout, status, total, err_acc) do
    receive do
      {:http, {^rid, :stream_start, headers}} ->
        code = stream_status(headers)
        stream_loop(rid, on_chunk, timeout, code, total, err_acc)

      {:http, {^rid, :stream, chunk}} when is_binary(chunk) ->
        if status in [nil, 200] do
          on_chunk.(chunk)
          stream_loop(rid, on_chunk, timeout, status, total + byte_size(chunk), err_acc)
        else
          stream_loop(rid, on_chunk, timeout, status, total, [chunk | err_acc])
        end

      {:http, {^rid, :stream_end, _headers}} ->
        if status in [nil, 200] do
          {:ok, total}
        else
          {:error, {status, decode(err_acc |> Enum.reverse() |> IO.iodata_to_binary())}}
        end

      # A non-streamable response (some errors arrive as one shot) — map like the buffered path.
      {:http, {^rid, {{_, code, _}, _headers, resp}}} ->
        if code in 200..299 do
          on_chunk.(resp)
          {:ok, byte_size(resp)}
        else
          {:error, {code, decode(resp)}}
        end

      {:http, {^rid, {:error, e}}} ->
        {:error, inspect(e)}
    after
      timeout ->
        :httpc.cancel_request(rid)
        {:error, :stream_timeout}
    end
  end

  # :httpc stream_start headers don't carry a status line; a start means the request was accepted
  # (errors arrive via the one-shot/error shapes above), so treat it as 200 unless told otherwise.
  defp stream_status(_headers), do: 200

  defp cap_body(bin) when is_binary(bin) and byte_size(bin) > @max_body_bytes,
    do: binary_part(bin, 0, @max_body_bytes)

  defp cap_body(bin), do: bin

  # JSON when it parses (error payloads, ASR results), raw bytes otherwise (audio).
  defp decode(""), do: %{}

  defp decode(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, v} -> v
      {:error, _} -> bin
    end
  end
end

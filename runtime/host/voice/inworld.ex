defmodule Workbooks.Voice.Inworld do
  @moduledoc """
  Host-brokered Inworld text-to-speech. The `INWORLD_API_KEY` (a base64
  `client:secret` passed as HTTP Basic) lives here and never reaches the agent
  sandbox or the client — same secrets-by-reference posture as the OpenRouter and
  ElevenLabs brokers.

  `stream/3` POSTs to the Inworld streaming endpoint, which replies with NDJSON:
  one JSON object per line, each `{"result":{"audioContent":"<base64>", ...}}`.
  We request `LINEAR16` so the client plays raw PCM with no decoder and can drop
  the buffer instantly on barge-in. Each decoded chunk is handed to `on_chunk`
  as it lands.

  Barge-in: the caller runs this inside a Task and kills it (the `stream: :self`
  httpc request is owned by that process and dies with it), or sends `{:cancel}`
  to this process for a graceful stop.
  """
  require Logger

  @endpoint ~c"https://api.inworld.ai/tts/v1/voice:stream"
  @default_model "inworld-tts-1.5-max"
  @default_voice "Ashley"
  @default_rate 24_000

  @doc """
  Synthesize `text`, invoking `on_chunk.(pcm_binary)` for each audio chunk.

  Blocks until the stream ends, errors, or is cancelled. Returns
  `{:ok, %{chars: n, bytes: n, sample_rate: r}}`, `{:ok, :cancelled}`, or
  `{:error, reason}`.

  Opts: `:voice`, `:model`, `:sample_rate`, `:encoding` (default LINEAR16).
  """
  def stream(text, on_chunk, opts \\ []) when is_binary(text) and is_function(on_chunk, 1) do
    :inets.start()
    :ssl.start()

    case Workbooks.Secrets.get("INWORLD_API_KEY") do
      nil ->
        {:error, :inworld_api_key_unset}

      key ->
        rate = opts[:sample_rate] || @default_rate

        body =
          Jason.encode!(%{
            text: text,
            voice_id: opts[:voice] || @default_voice,
            model_id: opts[:model] || @default_model,
            audio_config: %{
              audio_encoding: opts[:encoding] || "LINEAR16",
              sample_rate_hertz: rate
            }
          })

        headers = [
          {~c"authorization", ~c"Basic #{key}"},
          {~c"content-type", ~c"application/json"}
        ]

        req_opts = [sync: false, stream: :self, body_format: :binary]

        case :httpc.request(:post, {@endpoint, headers, ~c"application/json", body}, [timeout: 120_000], req_opts) do
          {:ok, req_id} ->
            collect(req_id, on_chunk, "", %{chars: String.length(text), bytes: 0, sample_rate: rate})

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Receive loop over the async httpc stream. `buf` holds a partial NDJSON tail
  # between chunks; `acc` tracks counts. A `{:cancel}` message aborts cleanly.
  defp collect(req_id, on_chunk, buf, acc) do
    receive do
      {:cancel} ->
        :httpc.cancel_request(req_id)
        {:ok, :cancelled}

      {:http, {^req_id, :stream_start, _headers}} ->
        collect(req_id, on_chunk, buf, acc)

      {:http, {^req_id, :stream, chunk}} ->
        {acc, buf} = consume(buf <> chunk, on_chunk, acc)
        collect(req_id, on_chunk, buf, acc)

      {:http, {^req_id, :stream_end, _headers}} ->
        {acc, _} = consume(buf <> "\n", on_chunk, acc)
        {:ok, acc}

      {:http, {^req_id, {{_, status, _}, _hdrs, resp}}} ->
        Logger.warning("inworld tts -> #{status}: #{String.slice(to_string(resp), 0, 300)}")
        {:error, {:http, status}}

      {:http, {^req_id, {:error, reason}}} ->
        {:error, reason}
    after
      120_000 ->
        :httpc.cancel_request(req_id)
        {:error, :inworld_stream_timeout}
    end
  end

  # Split off every COMPLETE NDJSON line, emit its PCM, return {acc, partial_tail}.
  defp consume(buf, on_chunk, acc) do
    parts = String.split(buf, "\n")
    {complete, [partial]} = Enum.split(parts, length(parts) - 1)
    acc = Enum.reduce(complete, acc, &emit_line(&1, on_chunk, &2))
    {acc, partial}
  end

  defp emit_line("", _on_chunk, acc), do: acc

  defp emit_line(line, on_chunk, acc) do
    with {:ok, %{"result" => %{"audioContent" => b64}}} <- Jason.decode(line),
         {:ok, pcm} <- Base.decode64(b64) do
      on_chunk.(pcm)
      %{acc | bytes: acc.bytes + byte_size(pcm)}
    else
      _ -> acc
    end
  end
end

defmodule Workbooks.Voice.Session do
  @moduledoc """
  Drives one turn of the voice loop: a finalized user transcript in, streamed
  spoken audio out. The brain (`Workbooks.Llm`) is streamed token-by-token; as
  soon as a full sentence lands it's handed to a linked TTS worker that
  synthesizes it via `Workbooks.Voice.Inworld` and pushes PCM to the client —
  so audio begins playing while the brain is still composing the rest.

  Barge-in is structural: `speak/4` returns the driving `Task`. The audio
  WebSocket kills that task on a barge-in signal; the TTS worker is `spawn_link`ed
  to it and the in-flight Inworld httpc stream is owned by the worker, so the kill
  tears the whole pipeline down — no half-spoken sentence keeps streaming.

  Frames pushed to `ws_pid` (consumed by `Workbooks.Voice.Stream`):
    {:tts_audio, pcm}        raw LINEAR16 chunk (binary frame to client)
    {:tts_text, map}         JSON control/caption (text frame to client)
  """
  require Logger

  @default_voice "Ashley"
  @sample_rate 24_000

  @system """
  You are a voice coding assistant inside the Workbooks desktop app. You are being
  spoken to and your replies are read aloud, so keep them short and conversational
  — usually one or two sentences. Don't read code or long lists out loud; briefly
  say what you did or ask a clarifying question. Be direct and warm.
  """

  @doc """
  Begin speaking a reply to `user_text`. Returns the driving `Task` (kill it to
  barge-in). `history` is a list of `%{role, content}` prior turns.
  """
  def speak(ws_pid, user_text, history, opts \\ []) do
    Task.async(fn -> run(ws_pid, user_text, history, opts) end)
  end

  defp run(ws_pid, user_text, history, opts) do
    voice = opts[:voice] || @default_voice
    push(ws_pid, %{type: "speaking_start", sample_rate: @sample_rate})

    worker = spawn_link(fn -> tts_loop(ws_pid, voice) end)
    mref = Process.monitor(worker)
    {:ok, buf} = Agent.start_link(fn -> "" end)

    on_delta = fn delta ->
      push(ws_pid, %{type: "reply_text", text: delta})
      Agent.update(buf, &(&1 <> delta))
      flush_sentences(buf, worker)
    end

    messages =
      [%{role: "system", content: @system}] ++
        Enum.map(history, &Map.take(&1, [:role, :content])) ++
        [%{role: "user", content: user_text}]

    # The voice brain wants low TTFT over raw smarts; WB_VOICE_BRAIN_MODEL lets a
    # deploy point it at a fast provider without touching the code lane (mercury-2).
    model = opts[:model] || System.get_env("WB_VOICE_BRAIN_MODEL")
    result = Workbooks.Llm.complete(messages, on_delta: on_delta, model: model)

    # Flush whatever sentence fragment is left, then close the worker.
    case Agent.get(buf, & &1) |> String.trim() do
      "" -> :ok
      tail -> send(worker, {:sentence, tail})
    end

    Agent.stop(buf)
    send(worker, :done)

    receive do
      {:DOWN, ^mref, :process, _, _} -> :ok
    after
      120_000 -> :ok
    end

    reply =
      case result do
        {:ok, %{content: c}} -> c
        _ -> ""
      end

    push(ws_pid, %{type: "speaking_end"})
    {:ok, reply}
  end

  # Pull every COMPLETE sentence out of the buffer and enqueue it for TTS, leaving
  # any trailing fragment for the next delta.
  defp flush_sentences(buf, worker) do
    text = Agent.get(buf, & &1)
    {sentences, rest} = take_sentences(text)

    if sentences != [] do
      Agent.update(buf, fn _ -> rest end)
      Enum.each(sentences, &send(worker, {:sentence, &1}))
    end
  end

  @doc false
  # Splits on sentence-final punctuation followed by whitespace. Returns
  # {complete_sentences, trailing_fragment}.
  def take_sentences(text) do
    case Regex.scan(~r/.*?[.!?](?=\s)/s, text) do
      [] ->
        {[], text}

      matches ->
        sentences = Enum.map(matches, fn [s] -> String.trim(s) end)
        consumed = Enum.join(matches |> Enum.map(fn [s] -> s end))
        rest = String.slice(text, String.length(consumed)..-1//1) |> String.trim_leading()
        {Enum.reject(sentences, &(&1 == "")), rest}
    end
  end

  # Synthesizes queued sentences one at a time, in order, pushing audio as it
  # streams. Lives as long as the driving task (spawn_link); dies with it on barge-in.
  defp tts_loop(ws_pid, voice) do
    receive do
      {:sentence, s} ->
        case clean(s) do
          "" ->
            :ok

          spoken ->
            Workbooks.Voice.Inworld.stream(spoken, fn pcm -> send(ws_pid, {:tts_audio, pcm}) end,
              voice: voice,
              sample_rate: @sample_rate
            )
        end

        tts_loop(ws_pid, voice)

      :done ->
        :ok
    after
      60_000 -> :ok
    end
  end

  defp push(ws_pid, map), do: send(ws_pid, {:tts_text, map})

  # Strip markdown so the voice never reads "asterisk asterisk" — code spans,
  # emphasis, and heading/list markers become plain spoken text.
  defp clean(text) do
    text
    |> String.replace(~r/`+/, "")
    |> String.replace(~r/[*_#>]+/, "")
    |> String.replace(~r/\s{2,}/, " ")
    |> String.trim()
  end
end


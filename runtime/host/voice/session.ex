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

  When the user asks you to write, generate, or change code, call the `write_code`
  tool with a clear, self-contained task description. The code is shown to the user
  in the editor — never speak it. After the tool returns, just say briefly what you
  did (e.g. "Done, I wrote the handler — want me to add tests?").
  """

  # Code generation goes to mercury-2, not the voice brain — fast diffusion model
  # tuned for code. Its output lands in the editor canvas, never spoken.
  @code_model "inception/mercury-2"

  @tools [
    %{
      type: "function",
      function: %{
        name: "write_code",
        description:
          "Generate or modify code for the user. The code is rendered in the editor, not spoken. " <>
            "Use whenever the user asks to write, build, fix, or change code.",
        parameters: %{
          type: "object",
          properties: %{
            task: %{
              type: "string",
              description:
                "A clear, self-contained description of the code to produce, including language and any relevant context."
            }
          },
          required: ["task"]
        }
      }
    }
  ]

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
    reply = agent_loop(messages, on_delta, ws_pid, model, 0)

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

    push(ws_pid, %{type: "speaking_end"})
    {:ok, reply}
  end

  # Run the brain until it stops calling tools (bounded). Spoken content streams
  # through on_delta on every pass; a write_code call routes to mercury-2 and its
  # output is pushed to the editor, then the brain narrates the result.
  defp agent_loop(_messages, _on_delta, _ws_pid, _model, depth) when depth >= 3, do: ""

  defp agent_loop(messages, on_delta, ws_pid, model, depth) do
    case Workbooks.Llm.complete(messages, on_delta: on_delta, model: model, tools: @tools) do
      {:ok, %{tool_calls: [], content: content}} ->
        content || ""

      {:ok, %{tool_calls: calls, raw_message: assistant}} ->
        tool_msgs = Enum.map(calls, &exec_tool(&1, ws_pid))
        agent_loop(messages ++ [strip(assistant) | tool_msgs], on_delta, ws_pid, model, depth + 1)

      {:error, _} ->
        ""
    end
  end

  defp exec_tool(%{name: "write_code", id: id, args: args}, ws_pid) do
    task = args["task"] || args["description"] || ""
    code = generate_code(task)
    push(ws_pid, %{type: "code", task: task, code: code})
    %{role: "tool", tool_call_id: id, content: "Done — code written and shown in the editor."}
  end

  defp exec_tool(%{id: id}, _ws_pid) do
    %{role: "tool", tool_call_id: id, content: "Unknown tool."}
  end

  defp generate_code(task) do
    case Workbooks.Llm.complete(
           [
             %{role: "system", content: "You are a code generator. Output only the code, no prose, no markdown fences."},
             %{role: "user", content: task}
           ],
           model: @code_model
         ) do
      {:ok, %{content: c}} when is_binary(c) -> c
      _ -> ""
    end
  end

  # Keep only the fields the chat API needs echoed back (mirrors Agent.strip/1).
  defp strip(assistant), do: Map.take(assistant, ["role", "content", "tool_calls"])

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


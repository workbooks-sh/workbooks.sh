defmodule Workbooks.Voice.Stream do
  @moduledoc """
  Bidirectional audio WebSocket for the voice agent. STT runs client-side
  (Moonshine), so the client sends finalized transcripts and barge-in signals as
  JSON text frames; the server streams spoken audio back as binary PCM frames
  plus JSON captions/markers.

  Client → server (text JSON):
    {"type":"transcript","text":"..."}   a finalized user utterance → respond
    {"type":"barge_in"}                  user started talking → cancel current reply
    {"auth":"..."}                       ignored (local desktop)

  Server → client:
    binary frame                         LINEAR16 PCM @ 24kHz mono
    {"type":"speaking_start","sample_rate":24000}
    {"type":"reply_text","text":"..."}   live caption deltas
    {"type":"speaking_end"}

  Barge-in kills the driving task; its linked TTS worker and in-flight Inworld
  stream die with it (see `Workbooks.Voice.Session`).
  """
  @behaviour WebSock
  require Logger

  @impl true
  def init(state) do
    {:ok, Map.merge(%{history: [], task: nil}, state)}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "transcript", "text" => t}} when is_binary(t) and t != "" ->
        {:ok, respond(t, state)}

      {:ok, %{"type" => "barge_in"}} ->
        {:ok, cancel(state)}

      _ ->
        {:ok, state}
    end
  end

  @impl true
  def handle_in(_frame, state), do: {:ok, state}

  # Audio + captions from the session pipeline.
  @impl true
  def handle_info({:tts_audio, pcm}, state), do: {:push, {:binary, pcm}, state}

  @impl true
  def handle_info({:tts_text, map}, state), do: {:push, {:text, Jason.encode!(map)}, state}

  # Driving task finished — append the assistant's reply to history.
  @impl true
  def handle_info({ref, {:ok, reply}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    history = state.history ++ [%{role: "assistant", content: reply}]
    {:ok, %{state | task: nil, history: history}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{task: %Task{ref: ref}} = state) do
    {:ok, %{state | task: nil}}
  end

  @impl true
  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{task: %Task{} = task}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Cancel any in-flight reply, record the user turn, start a fresh reply.
  defp respond(text, state) do
    state = cancel(state)
    history = state.history ++ [%{role: "user", content: text}]
    task = Workbooks.Voice.Session.speak(self(), text, state.history, voice: state[:voice], model: state[:model])
    %{state | history: history, task: task}
  end

  defp cancel(%{task: %Task{} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    %{state | task: nil}
  end

  defp cancel(state), do: state
end

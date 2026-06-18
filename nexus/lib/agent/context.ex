defmodule Nexus.Agent.Context do
  @moduledoc """
  Context management for the agent loop. Without it, a long-horizon run pays for the whole transcript
  every turn (cost grows quadratically) and the model rots on a wall of stale `bash` output. Two
  defences, both bounded and configurable:

    * **output truncation** — a single oversized `bash` result (a huge `cat`, a big fetch) is capped so
      it can't bloat every later turn. Head + tail kept, middle elided.
    * **sliding window** — keep the system message + the original task + the most-recent N messages.
      Older middle turns drop out; the agent keeps its instructions and recent working state.

  Defaults are generous so short runs are untouched; long runs get the savings.
  """

  @output_cap 8_000
  @window 24

  @doc "Cap a single bash output to `cap` chars (head + tail, middle elided)."
  def truncate(output, cap \\ @output_cap) do
    if byte_size(output) <= cap do
      output
    else
      keep = div(cap, 2)
      head = binary_part(output, 0, keep)
      tail = binary_part(output, byte_size(output) - keep, keep)
      head <> "\n… [#{byte_size(output) - cap} bytes elided] …\n" <> tail
    end
  end

  @doc """
  Keep the system message + the original task + the most recent `window` messages. Always keeps the
  first two (system, task) so the agent never loses its instructions, plus a sliding tail.
  """
  def window(messages, window \\ @window)

  def window(messages, window) when length(messages) <= window + 2, do: messages

  def window([system, task | rest], window) do
    [system, task | Enum.take(rest, -window)]
  end

  def window(messages, _window), do: messages
end

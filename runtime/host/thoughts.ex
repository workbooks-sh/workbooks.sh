defmodule Workbooks.Thoughts do
  @moduledoc """
  Waldo's visible inner monologue (lander follow-along). PURELY cosmetic and
  fully decoupled from the agent runtime: a tiny side model narrates the live
  step feed in ≤8 words for the page's cursor bubble.

  Lazy + debounced: a thought is only (re)generated when the public plane asks
  for one (someone is actually watching), at most once per @ttl_ms across ALL
  viewers, via a persistent_term cache + an in-flight lock. A failure or slow
  call degrades to the cached/last thought — never an error, never a stall.
  """
  require Logger

  @pt {__MODULE__, :cache}
  @lock {__MODULE__, :inflight}
  @ttl_ms 20_000

  @doc "Current thought text (or nil). `steps` is the recent live-step summary list."
  def current(_steps, false), do: nil

  def current(steps, true) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@pt, nil) do
      {ts, text} when now - ts < @ttl_ms ->
        text

      stale ->
        maybe_refresh(steps, now)
        with {_, text} <- stale, do: text, else: (_ -> nil)
    end
  end

  defp maybe_refresh(steps, now) do
    # single in-flight refresh across all pollers
    unless :persistent_term.get(@lock, false) do
      :persistent_term.put(@lock, true)

      Task.start(fn ->
        try do
          doing =
            steps
            |> Enum.take(3)
            |> Enum.map_join("; ", fn s -> "#{s.tool} #{s.target}" end)

          case Workbooks.Llm.complete(
                 [
                   %{role: "system", content: "You are Waldo, an agent maintaining a website, thinking out loud. Reply with ONE present-tense thought, max 8 words, lowercase, no quotes, no punctuation at the end. Concrete, about the work at hand."},
                   %{role: "user", content: "your last actions: #{doing}"}
                 ],
                 model: System.get_env("WB_THOUGHT_MODEL", "x-ai/grok-build-0.1"),
                 retries: 0,
                 temperature: 0.9
               ) do
            {:ok, %{content: text}} when is_binary(text) ->
              t = text |> String.trim() |> String.slice(0, 80)
              :persistent_term.put(@pt, {System.monotonic_time(:millisecond), t})

            _ ->
              # keep whatever was cached; just bump the clock so we don't hammer
              case :persistent_term.get(@pt, nil) do
                {_, text} -> :persistent_term.put(@pt, {System.monotonic_time(:millisecond), text})
                nil -> :persistent_term.put(@pt, {System.monotonic_time(:millisecond), nil})
              end
          end
        after
          :persistent_term.put(@lock, false)
        end
      end)
    end

    :ok
  rescue
    _ -> :ok
  end
end

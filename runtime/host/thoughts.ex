defmodule Workbooks.Thoughts do
  @moduledoc """
  An agent's visible inner monologue (lander follow-along). PURELY cosmetic and
  fully decoupled from the agent runtime: a tiny side model narrates the live
  step feed in ≤8 words for the page's cursor bubble.

  Lazy + debounced: a thought is only (re)generated when the public plane asks
  for one (someone is actually watching), at most once per @ttl_ms PER AGENT,
  via a persistent_term cache + an in-flight lock. A failure or slow call degrades
  to the cached/last thought — never an error, never a stall.

  ## Per-agent (wb-wc0.2)

  Each crew member narrates its OWN monologue: the cache + lock keys are
  namespaced by agent name, and the agent's name is passed into the system prompt
  (replacing the generic "an agent"). The singleton keeper passes `agent: nil` →
  the legacy single-narration behavior, byte-for-byte (key `{__MODULE__, :cache}`,
  prompt "an agent maintaining a website").
  """
  require Logger

  @ttl_ms 20_000

  # Cache / lock keys are namespaced by agent so two agents' thoughts never clash;
  # `nil` reproduces the exact legacy singleton keys.
  defp pt_key(nil), do: {__MODULE__, :cache}
  defp pt_key(agent), do: {__MODULE__, :cache, agent}
  defp lock_key(nil), do: {__MODULE__, :inflight}
  defp lock_key(agent), do: {__MODULE__, :inflight, agent}

  @doc """
  Current thought text (or nil). `steps` is the recent live-step summary list;
  `agent` is the crew member's name (nil for the singleton).
  """
  def current(steps, watching, agent \\ nil)
  def current(_steps, false, _agent), do: nil

  def current(steps, true, agent) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(pt_key(agent), nil) do
      {ts, text} when now - ts < @ttl_ms ->
        text

      stale ->
        maybe_refresh(steps, now, agent)
        with {_, text} <- stale, do: text, else: (_ -> nil)
    end
  end

  defp maybe_refresh(steps, _now, agent) do
    # single in-flight refresh per agent across all pollers
    unless :persistent_term.get(lock_key(agent), false) do
      :persistent_term.put(lock_key(agent), true)

      Task.start(fn ->
        try do
          doing =
            steps
            |> Enum.take(3)
            |> Enum.map_join("; ", fn s -> "#{s.tool} #{s.target}" end)

          # Name the agent in the prompt when we have one; else the generic voice.
          who = if agent, do: agent, else: "an agent"

          case Workbooks.Llm.complete(
                 [
                   %{role: "system", content: "You are #{who}, an agent maintaining a website, thinking out loud. Reply with ONE present-tense thought, max 8 words, lowercase, no quotes, no punctuation at the end. Concrete, about the work at hand."},
                   %{role: "user", content: "your last actions: #{doing}"}
                 ],
                 model: System.get_env("WB_THOUGHT_MODEL", "x-ai/grok-build-0.1"),
                 retries: 0,
                 temperature: 0.9
               ) do
            {:ok, %{content: text}} when is_binary(text) ->
              t = text |> tidy() |> String.slice(0, 80)
              :persistent_term.put(pt_key(agent), {System.monotonic_time(:millisecond), t})

            _ ->
              # keep whatever was cached; just bump the clock so we don't hammer
              case :persistent_term.get(pt_key(agent), nil) do
                {_, text} -> :persistent_term.put(pt_key(agent), {System.monotonic_time(:millisecond), text})
                nil -> :persistent_term.put(pt_key(agent), {System.monotonic_time(:millisecond), nil})
              end
          end
        after
          :persistent_term.put(lock_key(agent), false)
        end
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  # Small narration models love to wrap output in quotes/backticks despite the
  # prompt; strip wrapping + stray edge punctuation so the bubble reads clean.
  defp tidy(text) do
    text
    |> String.trim()
    |> String.trim(~s("))
    |> String.trim(~s('))
    |> String.trim("`")
    |> String.trim()
  end
end

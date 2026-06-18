defmodule Nexus.Agent.Context do
  @moduledoc """
  Context management for the agent loop. Without it, a long-horizon run pays for the whole transcript
  every turn (cost grows quadratically) and the model rots on a wall of stale `bash` output. The
  budget is measured in **tokens**, not message count — what the model (and the bill) actually cares
  about, and what stops a single huge message from slipping past a count-based window.

    * **output truncation** — a single oversized `bash` result is byte-capped before it ever becomes
      a message (head + tail kept, middle elided).
    * **token window** — keep the system message + the original task + the most recent messages that
      fit within the token budget; older middle turns drop out.
    * **compaction** — instead of dropping the overflow, summarize it into a compact running note, so
      an early fact survives a long run. `[system, task, running_summary, …recent-within-budget]`.

  Token counts are estimated (~4 chars/token — the standard cheap heuristic; no tokenizer dep).
  Defaults are generous so short runs are untouched.
  """

  @output_cap 8_000
  @token_budget 6_000
  @chars_per_token 4

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

  @doc "Estimate the token count of a string (~4 chars/token + 1). No tokenizer dependency."
  def est_tokens(text), do: div(byte_size(to_string(text)), @chars_per_token) + 1

  @doc "Estimate a message's tokens — content + any tool_calls + a little role framing."
  def msg_tokens(msg) do
    content = est_tokens(Map.get(msg, :content) || "")

    tools =
      case Map.get(msg, :tool_calls) do
        calls when is_list(calls) and calls != [] -> est_tokens(Jason.encode!(calls))
        _ -> 0
      end

    content + tools + 4
  end

  @doc "Total estimated tokens of a message list (what a turn would send)."
  def total_tokens(messages), do: Enum.reduce(messages, 0, &(msg_tokens(&1) + &2))

  @doc """
  Keep the system message + the original task + the most recent messages that fit within `budget`
  TOKENS. Always keeps system + task (instructions) and at least the most-recent message.
  """
  def window(messages, budget \\ @token_budget)

  def window([system, task | rest], budget), do: [system, task | recent_within(rest, budget)]
  def window(messages, _budget), do: messages

  @doc """
  Compaction — the solid method. When the recent messages overflow the token budget, the overflow is
  **summarized** into a compact running note (compounding any prior summary) instead of dropped, so an
  early fact survives. `summarize` is `fn text -> summary` (injected — `Nexus.Llm` in the loop, a stub
  in tests). No-op (and no summarizer call) while the whole transcript fits the budget.
  """
  def compact(messages, summarize, budget \\ @token_budget)

  def compact([system, task | rest], summarize, budget) do
    {prior, rest2} = pop_summary(rest)
    # budget shared between the running summary and the recent tail.
    summary_cost = if prior, do: est_tokens(prior) + 4, else: 0
    recent = recent_within(rest2, budget - summary_cost)
    overflow = Enum.take(rest2, length(rest2) - length(recent))

    cond do
      overflow == [] and is_nil(prior) ->
        [system, task | rest2]

      overflow == [] ->
        [system, task, summary_msg(prior) | recent]

      true ->
        digest = Enum.map_join(overflow, "\n", &line/1)
        summary = summarize.("Summary so far:\n#{prior || "(none)"}\n\nNewer turns to fold in:\n#{digest}")
        [system, task, summary_msg(summary) | recent]
    end
  end

  def compact(messages, _summarize, _budget), do: messages

  # The most recent messages whose cumulative tokens fit `budget` (always keep ≥1), chronological.
  defp recent_within(msgs, budget) do
    msgs
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn m, {acc, used} ->
      t = msg_tokens(m)

      cond do
        acc == [] -> {:cont, {[m], used + t}}
        used + t <= budget -> {:cont, {[m | acc], used + t}}
        true -> {:halt, {acc, used}}
      end
    end)
    |> elem(0)
  end

  # Pull a prior running-summary message out of the list (so summaries compound, never duplicate).
  defp pop_summary(msgs) do
    case Enum.split_with(msgs, &summary?/1) do
      {[%{content: "Summary of earlier turns:\n" <> s} | _], rest} -> {s, rest}
      {[], rest} -> {nil, rest}
    end
  end

  defp summary?(%{role: "system", content: "Summary of earlier turns:\n" <> _}), do: true
  defp summary?(_), do: false

  defp summary_msg(text), do: %{role: "system", content: "Summary of earlier turns:\n#{text}"}

  defp line(%{role: role, content: content}), do: "#{role}: #{String.slice(to_string(content), 0, 400)}"
  defp line(_), do: ""
end

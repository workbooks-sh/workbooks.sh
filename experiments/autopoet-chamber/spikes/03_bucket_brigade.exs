# Spike 3 — Economic credit assignment: ZCS bucket brigade (Holland/Wilson)
#
# HYPOTHESIS: a population of tiny condition→action rules with WEALTH (strength) as the
# only learning signal — pay-to-act, get-paid-on-outcome, reproduce-when-rich,
# die-when-poor — learns a task with NO gradients, NO global coordination. This is the
# proven math (Wilson's ZCS, 1994; Holland's bucket brigade) for the autopoet economy:
# components earn credit when their action chain leads to reward.
#
# MODE A (baseline science): single-step ZCS on the 6-multiplexer — the classic LCS
#   benchmark. Chance = 50%. Reference systems reach ~90%+.
#
# MODE B (the pathway claim): a TWO-LAYER chain. Layer-1 rules see the 6-bit input and
#   can only emit a 2-bit MESSAGE. Layer-2 rules see ONLY the message and answer 0/1.
#   External reward touches ONLY layer 2; layer 1 is paid exclusively through the
#   bucket brigade (layer 2's bids flow backward). If accuracy rises above chance, an
#   internal communication pathway was LEARNED purely from economic credit — the
#   micro-version of "the bus becomes a learned pathway".
#
# KPI: rolling accuracy vs episodes; wealth concentration; the evolved rules themselves.

:rand.seed(:exsss, {2026, 7, 1})

defmodule Mux do
  # 6-multiplexer: input {a1,a0,d0,d1,d2,d3}; answer = data bit selected by address.
  def input, do: List.to_tuple(for _ <- 1..6, do: :rand.uniform(2) - 1)
  def answer(x), do: elem(x, 2 + elem(x, 0) * 2 + elem(x, 1))
end

defmodule ZCS do
  # rule = {cond_tuple, action, strength}; cond allele ∈ {0, 1, :h} (:h = don't-care).
  # eps: ε-greedy exploration — without it, roulette collapses the message protocol in
  # chained mode before the downstream layer can assign semantics (observed empirically:
  # strict roulette + strict bucket brigade sat at chance for 48k episodes).
  defstruct rules: [], beta: 0.2, tau: 0.1, s0: 20.0, ga_p: 0.25, mut: 0.01, cover_h: 0.33, eps: 0.0

  def new(n, cond_len, actions, opts \\ []) do
    rules =
      for _ <- 1..n do
        cond = List.to_tuple(for _ <- 1..cond_len, do: random_allele(0.33))
        {cond, Enum.random(actions), 20.0}
      end

    struct(%__MODULE__{rules: rules}, opts)
  end

  defp random_allele(p_h) do
    r = :rand.uniform()
    cond do
      r < p_h -> :h
      r < p_h + (1 - p_h) / 2 -> 0
      true -> 1
    end
  end

  def matches?({cond, _, _}, x) do
    Enum.all?(0..(tuple_size(cond) - 1), fn i ->
      a = elem(cond, i)
      a == :h or a == elem(x, i)
    end)
  end

  # Returns {action, action_set_indices, zcs} — covering if nothing matches.
  def act(zcs, x, actions) do
    matches = for {r, i} <- Enum.with_index(zcs.rules), matches?(r, x), do: {r, i}

    if matches == [] do
      cover(zcs, x, actions)
    else
      by_action = Enum.group_by(matches, fn {{_, a, _}, _} -> a end)

      totals = Map.new(by_action, fn {a, rs} -> {a, Enum.sum(for {{_, _, s}, _} <- rs, do: s)} end)

      action =
        if :rand.uniform() < zcs.eps,
          do: Enum.random(Map.keys(by_action)),
          else: roulette(totals)

      {action, Enum.map(by_action[action], &elem(&1, 1)), zcs}
    end
  end

  defp cover(zcs, x, actions) do
    mean_s = Enum.sum(for {_, _, s} <- zcs.rules, do: s) / max(length(zcs.rules), 1)
    cond = List.to_tuple(for i <- 0..(tuple_size(x) - 1), do: if(:rand.uniform() < zcs.cover_h, do: :h, else: elem(x, i)))
    rule = {cond, Enum.random(actions), mean_s}
    weakest = zcs.rules |> Enum.with_index() |> Enum.min_by(fn {{_, _, s}, _} -> s end) |> elem(1)
    zcs = %{zcs | rules: List.replace_at(zcs.rules, weakest, rule)}
    act(zcs, x, actions)
  end

  defp roulette(totals) do
    sum = totals |> Map.values() |> Enum.sum()
    r = :rand.uniform() * max(sum, 1.0e-9)

    Enum.reduce_while(totals, 0.0, fn {a, s}, acc ->
      if acc + s >= r, do: {:halt, a}, else: {:cont, acc + s}
    end)
    |> case do
      a when not is_float(a) -> a
      _ -> totals |> Map.keys() |> hd()
    end
  end

  # Action set pays beta*S into a bucket; receives share of `income` (reward and/or an
  # upstream bucket). Non-selected matchers pay tax. Returns {bucket, zcs}.
  def settle(zcs, action_set, income) do
    n = length(action_set)

    {bucket, rules} =
      zcs.rules
      |> Enum.with_index()
      |> Enum.map_reduce(0.0, fn {{c, a, s}, i}, bkt ->
        if i in action_set do
          bid = zcs.beta * s
          {{c, a, s - bid + income / n}, bkt + bid}
        else
          {{c, a, s}, bkt}
        end
      end)
      |> then(fn {rules, bkt} -> {bkt, rules} end)

    {bucket, %{zcs | rules: rules}}
  end

  def tax_losers(zcs, x, action_set) do
    rules =
      zcs.rules
      |> Enum.with_index()
      |> Enum.map(fn {{c, a, s} = r, i} ->
        if i not in action_set and matches?(r, x), do: {c, a, s * (1 - zcs.tau)}, else: r
      end)

    %{zcs | rules: rules}
  end

  # Panmictic GA: roulette-select 2 parents by strength, 1-pt crossover, mutate, offspring
  # take half of each parent's strength (strength is CONSERVED), replace the 2 weakest.
  def ga(zcs, actions) do
    if :rand.uniform() > zcs.ga_p do
      zcs
    else
      idx = Enum.with_index(zcs.rules)
      totals = Map.new(idx, fn {{_, _, s}, i} -> {i, s} end)
      p1 = roulette(totals)
      p2 = roulette(Map.delete(totals, p1))
      {c1, a1, s1} = Enum.at(zcs.rules, p1)
      {c2, a2, s2} = Enum.at(zcs.rules, p2)

      cut = :rand.uniform(tuple_size(c1) - 1)
      child_c1 = splice(c1, c2, cut) |> mutate(zcs.mut)
      child_c2 = splice(c2, c1, cut) |> mutate(zcs.mut)
      kid1 = {child_c1, mut_action(a1, actions, zcs.mut), s1 / 2}
      kid2 = {child_c2, mut_action(a2, actions, zcs.mut), s2 / 2}

      rules =
        zcs.rules
        |> List.update_at(p1, fn {c, a, s} -> {c, a, s / 2} end)
        |> List.update_at(p2, fn {c, a, s} -> {c, a, s / 2} end)

      weakest2 =
        rules |> Enum.with_index() |> Enum.sort_by(fn {{_, _, s}, _} -> s end) |> Enum.take(2) |> Enum.map(&elem(&1, 1))

      rules =
        rules
        |> List.replace_at(Enum.at(weakest2, 0), kid1)
        |> List.replace_at(Enum.at(weakest2, 1), kid2)

      %{zcs | rules: rules}
    end
  end

  defp splice(c1, c2, cut) do
    l1 = Tuple.to_list(c1)
    l2 = Tuple.to_list(c2)
    List.to_tuple(Enum.take(l1, cut) ++ Enum.drop(l2, cut))
  end

  defp mutate(cond, p) do
    cond
    |> Tuple.to_list()
    |> Enum.map(fn a -> if :rand.uniform() < p, do: Enum.random([0, 1, :h] -- [a]), else: a end)
    |> List.to_tuple()
  end

  defp mut_action(a, actions, p), do: if(:rand.uniform() < p, do: Enum.random(actions), else: a)

  def wealth_top_decile(zcs) do
    sorted = zcs.rules |> Enum.map(fn {_, _, s} -> s end) |> Enum.sort(:desc)
    top = Enum.take(sorted, max(div(length(sorted), 10), 1)) |> Enum.sum()
    top / max(Enum.sum(sorted), 1.0e-9)
  end

  def top_rules(zcs, n) do
    zcs.rules
    |> Enum.sort_by(fn {_, _, s} -> -s end)
    |> Enum.take(n)
    |> Enum.map(fn {c, a, s} ->
      cs = c |> Tuple.to_list() |> Enum.map_join(fn :h -> "#"; b -> to_string(b) end)
      "#{cs} -> #{inspect(a)}  ($#{Float.round(s, 1)})"
    end)
  end
end

defmodule ModeA do
  def run(episodes) do
    zcs = ZCS.new(400, 6, [0, 1])
    IO.puts("--- MODE A: single-step ZCS on 6-multiplexer (pop 400, chance = 0.500) ---")
    loop(zcs, 1, episodes, [])
  end

  defp loop(zcs, ep, max, window) when ep > max do
    IO.puts("  final rolling(1000) accuracy: #{fmt(avg(window))}")
    IO.puts("  wealth held by top 10% of rules: #{fmt(ZCS.wealth_top_decile(zcs))}")
    IO.puts("  strongest evolved rules (cond a1 a0 d0 d1 d2 d3 -> action):")
    for r <- ZCS.top_rules(zcs, 6), do: IO.puts("    " <> r)
    zcs
  end

  defp loop(zcs, ep, max, window) do
    x = Mux.input()
    {action, aset, zcs} = ZCS.act(zcs, x, [0, 1])
    correct = action == Mux.answer(x)
    reward = if correct, do: 100.0, else: 0.0
    {_bucket, zcs} = ZCS.settle(zcs, aset, reward)
    zcs = zcs |> ZCS.tax_losers(x, aset) |> ZCS.ga([0, 1])

    window = [if(correct, do: 1, else: 0) | Enum.take(window, 999)]

    if rem(ep, 4000) == 0, do: IO.puts("  ep #{ep}: rolling accuracy #{fmt(avg(window))}")
    loop(zcs, ep + 1, max, window)
  end

  defp avg([]), do: 0.0
  defp avg(l), do: Enum.sum(l) / length(l)
  defp fmt(x), do: :io_lib.format("~.3f", [x * 1.0]) |> to_string()
end

defmodule ModeB do
  @messages [0, 1, 2, 3]

  def run(episodes) do
    l1 = ZCS.new(500, 6, @messages, eps: 0.10)
    l2 = ZCS.new(64, 2, [0, 1], ga_p: 0.15, eps: 0.10)

    IO.puts("\n--- MODE B: two-layer chain — credit flows ONLY from the final outcome ---")
    IO.puts("    layer1: 6-bit input -> 2-bit message (pop 500) | layer2: message -> answer (pop 64)")
    IO.puts("    credit: episodic profit-sharing (Grefenstette PSP) — layer1 share is discounted;")
    IO.puts("    NOTE: strict per-step bucket brigade was tried first and sat at chance (protocol collapse).")
    loop(l1, l2, 1, episodes, [], %{})
  end

  defp msg_bits(m), do: {div(m, 2), rem(m, 2)}

  defp loop(l1, l2, ep, max, window, contingency) when ep > max do
    IO.puts("  final rolling(1000) accuracy: #{fmt(avg(window))} (chance 0.500)")
    IO.puts("  layer1 wealth top-decile share: #{fmt(ZCS.wealth_top_decile(l1))}")
    IO.puts("  learned protocol P(correct answer | message), final 2000 eps:")

    for m <- @messages do
      row = Map.get(contingency, m, %{0 => 0, 1 => 0})
      n = max(row[0] + row[1], 1)
      IO.puts("    msg #{m |> msg_bits() |> inspect()}: n=#{n}  ans0=#{fmt(row[0] / n)}  ans1=#{fmt(row[1] / n)}")
    end

    IO.puts("  layer2 strongest rules (message bits -> answer):")
    for r <- ZCS.top_rules(l2, 4), do: IO.puts("    " <> r)
  end

  defp loop(l1, l2, ep, max, window, contingency) do
    x = Mux.input()
    truth = Mux.answer(x)

    {msg, aset1, l1} = ZCS.act(l1, x, @messages)
    {ans, aset2, l2} = ZCS.act(l2, msg_bits(msg), [0, 1])

    correct = ans == truth
    reward = if correct, do: 100.0, else: 0.0

    # Episodic profit sharing: BOTH action sets are paid only when the CHAIN's final
    # outcome earns reward; layer 1's share is discounted. Informationally identical to
    # bucket brigade's promise (credit from outcome only) but without the two-timescale
    # bootstrap instability of per-step bid flow.
    {_b2, l2} = ZCS.settle(l2, aset2, 0.30 * reward)
    {_b1, l1} = ZCS.settle(l1, aset1, 0.21 * reward)

    l1 = l1 |> ZCS.tax_losers(x, aset1) |> ZCS.ga(@messages)
    l2 = l2 |> ZCS.tax_losers(msg_bits(msg), aset2) |> ZCS.ga([0, 1])

    window = [if(correct, do: 1, else: 0) | Enum.take(window, 999)]

    contingency =
      if ep > max - 2000 do
        Map.update(contingency, msg, %{truth => 1, (1 - truth) => 0}, fn row ->
          Map.update(row, truth, 1, &(&1 + 1))
        end)
      else
        contingency
      end

    if rem(ep, 8000) == 0, do: IO.puts("  ep #{ep}: rolling accuracy #{fmt(avg(window))}")
    loop(l1, l2, ep + 1, max, window, contingency)
  end

  defp avg([]), do: 0.0
  defp avg(l), do: Enum.sum(l) / length(l)
  defp fmt(x), do: :io_lib.format("~.3f", [x * 1.0]) |> to_string()
end

IO.puts("\n=== Spike 3: economic credit assignment (ZCS / bucket brigade) ===\n")
ModeA.run(20_000)
ModeB.run(48_000)
IO.puts("")

# Spike 1 — Hebbian plasticity on the workspace graph
#
# HYPOTHESIS: a Hebbian rule (bounded potentiation + passive decay) over doc-to-doc
# transition edges, read back through spreading activation, predicts the next doc access
# better than static baselines — and, critically, ADAPTS after the workload drifts,
# where a cumulative count model (no decay) drags its stale history behind it.
#
# This is the math that would live on Nexus backlink/transition edges: every hook fire,
# doc open, or agent traversal is a co-activation event. The learner here is exactly
# "w += eta*(1-w) on co-activation; w *= d^dt passive decay" — Hebb with a leaky trace,
# the standard stabilized form (bounded in [0,1], forgetting built in).
#
# Learners compared (identical spreading-activation readout; ONLY the plasticity differs):
#   hebb    — eta-potentiation, multiplicative decay (the proposed mechanism)
#   counts  — additive counts, no decay (cumulative Markov; the "never forgets" baseline)
#   freq    — global top-k most frequent docs (no structure)
#   recency — last k distinct docs (no learning)
#
# KPI: top-3 next-access hit rate, split pre-drift / post-drift, + recovery speed.
# Deterministic: fixed seed.

:rand.seed(:exsss, {42, 1337, 7})

defmodule Cfg do
  def n_docs, do: 240
  def n_tasks, do: 12
  def path_len, do: 6
  def total_events, do: 24_000
  def drift_at, do: 12_000
  def p_insert_noise, do: 0.10
  def p_skip, do: 0.08
  def topk, do: 3
  def eta, do: 0.35
  def decay, do: 0.9985
  def spread_beta, do: 0.40
  def trace, do: [1.0, 0.45, 0.20]
end

defmodule World do
  # Latent structure: tasks are fixed doc paths. Sessions pick a task (zipf-ish) and walk
  # it with noise. At drift, half the tasks are replaced — the workload changes regime.
  def gen_tasks(k), do: for(_ <- 1..k, do: Enum.take_random(0..(Cfg.n_docs() - 1), Cfg.path_len()))

  def zipf_pick(tasks) do
    n = length(tasks)
    weights = for i <- 1..n, do: 1.0 / i
    total = Enum.sum(weights)
    r = :rand.uniform() * total

    {idx, _} =
      Enum.reduce_while(Enum.with_index(weights), {0, 0.0}, fn {w, i}, {_, acc} ->
        if acc + w >= r, do: {:halt, {i, acc}}, else: {:cont, {i, acc + w}}
      end)

    Enum.at(tasks, idx)
  end

  def walk(path) do
    Enum.flat_map(path, fn doc ->
      cond do
        :rand.uniform() < Cfg.p_skip() -> []
        :rand.uniform() < Cfg.p_insert_noise() -> [:rand.uniform(Cfg.n_docs()) - 1, doc]
        true -> [doc]
      end
    end)
  end

  # Infinite-ish access stream with a drift point.
  def stream do
    tasks_a = gen_tasks(Cfg.n_tasks())
    drifted = Enum.take(tasks_a, div(Cfg.n_tasks(), 2)) ++ gen_tasks(div(Cfg.n_tasks(), 2))
    gen(tasks_a, drifted, [])
  end

  defp gen(tasks_a, tasks_b, acc) do
    if length(acc) >= Cfg.total_events() + 10 do
      Enum.take(acc, Cfg.total_events() + 10)
    else
      tasks = if length(acc) >= Cfg.drift_at(), do: tasks_b, else: tasks_a
      gen(tasks_a, tasks_b, acc ++ walk(zipf_pick(tasks)))
    end
  end
end

defmodule Graph do
  # Edge store: %{src => %{dst => {w, t_last}}}. Decay applied lazily at read/write.
  def new, do: %{}

  def eff(w, t_last, t), do: w * :math.pow(Cfg.decay(), t - t_last)

  # decay? false => cumulative counts (w += 1, no decay): the baseline plasticity.
  def bump(g, a, b, t, true) do
    edges = Map.get(g, a, %{})
    {w0, tl} = Map.get(edges, b, {0.0, t})
    w = eff(w0, tl, t)
    Map.put(g, a, Map.put(edges, b, {w + Cfg.eta() * (1.0 - w), t}))
  end

  def bump(g, a, b, t, false) do
    edges = Map.get(g, a, %{})
    {w0, _} = Map.get(edges, b, {0.0, t})
    Map.put(g, a, Map.put(edges, b, {w0 + 1.0, t}))
  end

  def out(g, a, t, decay?) do
    edges = Map.get(g, a, %{})

    if decay? do
      for {dst, {w, tl}} <- edges, into: %{}, do: {dst, eff(w, tl, t)}
    else
      # counts baseline: normalize to per-source transition probabilities so the readout
      # scale matches hebb's bounded [0,1] weights (else 2-hop products of raw counts
      # blow up and the comparison measures the readout, not the plasticity rule).
      total = edges |> Enum.map(fn {_, {w, _}} -> w end) |> Enum.sum() |> max(1.0)
      for {dst, {w, _}} <- edges, into: %{}, do: {dst, w / total}
    end
  end

  # Spreading activation from the recent-access trace: 1-hop from each traced node
  # (activation-weighted) + damped 2-hop from the current node.
  def predict(g, trace_docs, t, decay?) do
    one_hop =
      trace_docs
      |> Enum.zip(Cfg.trace())
      |> Enum.reduce(%{}, fn {doc, act}, acc ->
        Enum.reduce(out(g, doc, t, decay?), acc, fn {dst, w}, a ->
          Map.update(a, dst, act * w, &(&1 + act * w))
        end)
      end)

    scores =
      case trace_docs do
        [cur | _] ->
          Enum.reduce(out(g, cur, t, decay?), one_hop, fn {mid, w1}, acc ->
            Enum.reduce(out(g, mid, t, decay?), acc, fn {dst, w2}, a ->
              Map.update(a, dst, Cfg.spread_beta() * w1 * w2, &(&1 + Cfg.spread_beta() * w1 * w2))
            end)
          end)

        [] ->
          one_hop
      end

    scores |> Enum.sort_by(fn {_, s} -> -s end) |> Enum.take(Cfg.topk()) |> Enum.map(&elem(&1, 0))
  end
end

defmodule Run do
  def main do
    events = World.stream()

    state = %{
      hebb: Graph.new(),
      counts: Graph.new(),
      freq: %{},
      trace: [],
      hits: %{hebb: [], counts: [], freq: [], recency: []}
    }

    final =
      events
      |> Enum.with_index()
      |> Enum.reduce(state, fn {doc, t}, st ->
        # ---- predict (prequential: before seeing the answer) ----
        hits =
          if st.trace == [] do
            st.hits
          else
            preds = %{
              hebb: Graph.predict(st.hebb, st.trace, t, true),
              counts: Graph.predict(st.counts, st.trace, t, false),
              freq: st.freq |> Enum.sort_by(fn {_, c} -> -c end) |> Enum.take(Cfg.topk()) |> Enum.map(&elem(&1, 0)),
              recency: Enum.take(st.trace, Cfg.topk())
            }

            Map.new(st.hits, fn {k, hs} -> {k, [{t, if(doc in preds[k], do: 1, else: 0)} | hs]} end)
          end

        # ---- update ----
        {hebb, counts} =
          case st.trace do
            [prev | _] -> {Graph.bump(st.hebb, prev, doc, t, true), Graph.bump(st.counts, prev, doc, t, false)}
            [] -> {st.hebb, st.counts}
          end

        %{
          st
          | hebb: hebb,
            counts: counts,
            freq: Map.update(st.freq, doc, 1, &(&1 + 1)),
            trace: [doc | Enum.take(st.trace, 2) |> Enum.reject(&(&1 == doc))] |> Enum.take(3),
            hits: hits
        }
      end)

    report(final.hits)
  end

  defp rate(hs, lo, hi) do
    win = for {t, h} <- hs, t >= lo and t < hi, do: h
    if win == [], do: 0.0, else: Enum.sum(win) / length(win)
  end

  defp recovery(hs, baseline) do
    # events after drift until rolling(500) hit-rate >= 90% of pre-drift baseline
    sorted = hs |> Enum.filter(fn {t, _} -> t >= Cfg.drift_at() end) |> Enum.sort_by(&elem(&1, 0))
    vals = Enum.map(sorted, &elem(&1, 1))
    target = 0.9 * baseline
    w = 500

    0..(max(length(vals) - w, 0))
    |> Enum.find(fn i -> vals |> Enum.slice(i, w) |> then(&(Enum.sum(&1) / w)) >= target end)
    |> case do
      nil -> "never (within #{length(vals)} ev)"
      i -> "#{i + w} events"
    end
  end

  defp report(hits) do
    d = Cfg.drift_at()

    IO.puts("\n=== Spike 1: Hebbian graph plasticity — top-#{Cfg.topk()} next-access hit rate ===\n")

    IO.puts(
      String.pad_trailing("learner", 10) <>
        String.pad_trailing("warmup", 10) <>
        String.pad_trailing("pre-drift", 12) <>
        String.pad_trailing("post-drift", 12) <>
        String.pad_trailing("settled", 10) <> "recovery-to-90%-of-pre"
    )

    for {name, hs} <- Enum.sort(hits) do
      pre = rate(hs, d - 4000, d)

      IO.puts(
        String.pad_trailing(to_string(name), 10) <>
          String.pad_trailing(fmt(rate(hs, 0, 2000)), 10) <>
          String.pad_trailing(fmt(pre), 12) <>
          String.pad_trailing(fmt(rate(hs, d, d + 2000)), 12) <>
          String.pad_trailing(fmt(rate(hs, d + 4000, d + 8000)), 10) <>
          recovery(hs, pre)
      )
    end

    IO.puts("""

    READ: hebb vs counts isolates the plasticity rule (same readout). Drift at event #{d}
    replaces half the latent tasks. A learning pathway layer must NOT be a frozen index —
    decay is what buys re-learning. freq/recency are the no-structure floors.
    """)
  end

  defp fmt(r), do: :io_lib.format("~.3f", [r]) |> to_string()
end

Run.main()

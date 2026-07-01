# Spike 2 — Surprise-gated cognition (active-inference economics)
#
# HYPOTHESIS: a cheap online predictor over the event stream can gate calls to an
# expensive "cortex" (LLM) so the system pays cortex prices ONLY for surprising events,
# holding near-perfect quality at a fraction of always-call cost. Attention should flow
# to novelty: escalation rate must spike right after a regime switch, then settle as the
# reflex layer re-learns.
#
# The predictor is a decayed-count conditional model p(next | prev) — the cheapest thing
# that can run per-event inside the bus dispatch path (Nexus.Events.emit). Surprise is
# -log2 p. This is the standard prequential/active-inference surprise measure.
#
# Handling model:
#   reflex — correct iff the event is among the top-3 predicted for its context (a cached
#            pathway exists). cost 1.
#   cortex — always correct. cost 200 (a cheap LLM call vs an in-process handler).
#
# Policies: always-cortex / never / static gate (sweep θ) / adaptive gate (PI-controlled
# escalation budget). KPI: cost-vs-quality frontier + post-switch escalation dynamics.

:rand.seed(:exsss, {7, 42, 99})

defmodule Cfg do
  def n_types, do: 40
  def n_regimes, do: 4
  def regime_support, do: 6
  def p_switch, do: 1 / 400
  def total, do: 40_000
  def decay, do: 0.995
  def alpha, do: 0.5
  def top_m, do: 3
  def cost_reflex, do: 1.0
  def cost_cortex, do: 200.0
  def anomaly_theta, do: 4.0
end

defmodule World do
  # Each regime: a sparse categorical over event types with a bit of context structure —
  # the distribution over "next" depends weakly on "prev" (shifted support per prev bucket).
  def gen_regime do
    support = Enum.take_random(0..(Cfg.n_types() - 1), Cfg.regime_support())
    weights = for _ <- support, do: :rand.uniform()
    total = Enum.sum(weights)
    Enum.zip(support, Enum.map(weights, &(&1 / total)))
  end

  def sample(dist) do
    r = :rand.uniform()

    Enum.reduce_while(dist, 0.0, fn {t, p}, acc ->
      if acc + p >= r, do: {:halt, t}, else: {:cont, acc + p}
    end)
    |> case do
      t when is_integer(t) -> t
      _ -> elem(hd(dist), 0)
    end
  end

  def stream do
    regimes = for _ <- 1..Cfg.n_regimes(), do: gen_regime()

    Enum.map_reduce(1..Cfg.total(), {0, []}, fn _, {ridx, switches} ->
      {ridx, switches} =
        if :rand.uniform() < Cfg.p_switch(),
          do: {rem(ridx + 1 + :rand.uniform(Cfg.n_regimes() - 1) - 1, Cfg.n_regimes()), [true | switches]},
          else: {ridx, [false | switches]}

      {{sample(Enum.at(regimes, ridx)), hd(switches)}, {ridx, switches}}
    end)
    |> elem(0)
  end
end

defmodule Predictor do
  # Per-context decayed counts with lazy exponential decay (scale trick preserves ratios).
  # state: %{ctx => {counts_map, total, t_last}}
  def new, do: %{}

  def probs(state, ctx, t) do
    {counts, total, tl} = Map.get(state, ctx, {%{}, 0.0, t})
    d = :math.pow(Cfg.decay(), t - tl)
    denom = total * d + Cfg.alpha() * Cfg.n_types()
    {counts, d, denom}
  end

  def p(state, ctx, e, t) do
    {counts, d, denom} = probs(state, ctx, t)
    (Map.get(counts, e, 0.0) * d + Cfg.alpha()) / denom
  end

  def top(state, ctx, t, m) do
    {counts, _d, _} = probs(state, ctx, t)
    counts |> Enum.sort_by(fn {_, c} -> -c end) |> Enum.take(m) |> Enum.map(&elem(&1, 0))
  end

  def update(state, ctx, e, t) do
    {counts, total, tl} = Map.get(state, ctx, {%{}, 0.0, t})
    d = :math.pow(Cfg.decay(), t - tl)
    counts = Map.new(counts, fn {k, c} -> {k, c * d} end)
    counts = Map.update(counts, e, 1.0, &(&1 + 1.0))
    Map.put(state, ctx, {counts, total * d + 1.0, t})
  end
end

defmodule Run do
  # Two distinct gates, cleanly separated:
  #   COMPETENCE gate — "do I have a compiled pathway for (ctx, event)?" Exactly knowable
  #     (a cache lookup). Miss → escalate to cortex, which INSTALLS a handler: the
  #     cortex's answer becomes a cached reflex (the autopoet writing a hook/rule).
  #     JIT-compiled cognition: pay cortex price once per novel situation.
  #   SURPRISE gate — -log2 p̂(event|ctx) from the decayed-count predictor. Not a cost
  #     gate; it is the ANOMALY/attention channel (what to look at, what to log, what
  #     to wake the autopoet for). KPI: it must spike at regime switches + self-quench.
  def main do
    events = World.stream()

    IO.puts("\n=== Spike 2: surprise-gated cognition — JIT-compiled cognition + anomaly attention ===\n")
    IO.puts("stream: #{Cfg.total()} events, #{Cfg.n_regimes()} regimes, p(switch)=#{Float.round(Cfg.p_switch(), 4)}/event")
    IO.puts("costs: reflex=#{Cfg.cost_reflex()}, cortex=#{Cfg.cost_cortex()}; handlers expire after #{handler_ttl()} events unused\n")

    IO.puts(
      String.pad_trailing("policy", 26) <>
        String.pad_trailing("quality", 10) <>
        String.pad_trailing("cost/ev", 10) <>
        String.pad_trailing("vs always", 11) <> "escalation%"
    )

    row("always-cortex", %{quality: 1.0, cost: Cfg.cost_cortex(), esc_rate: 1.0})

    never = simulate_reflex_only(events)
    row("reflex-only (top-#{Cfg.top_m()})", never)

    cache = simulate_cache(events)
    row("escalate-on-miss + install", Map.take(cache, [:quality, :cost, :esc_rate]))

    IO.puts("\nCOST CURVE (escalate-on-miss + install): mean cost/event per 5k-event window —")
    IO.puts("  " <> Enum.map_join(cache.curve, "  ", &fmt2/1))
    IO.puts("  (amortization: early windows pay for compilation; steady state approaches reflex cost)")
    IO.puts("  live handlers at end: #{cache.handlers}")

    IO.puts("""

    ANOMALY ATTENTION (surprise channel, independent of cost): escalation-worthy surprise
    (s > #{Cfg.anomaly_theta()}) in the 60 events after a regime switch vs steady state:
      after-switch: #{fmt(cache.post_switch)}   steady: #{fmt(cache.steady)}   ratio: #{Float.round(cache.post_switch / max(cache.steady, 1.0e-9), 1)}x
    """)
  end

  def handler_ttl, do: 4000

  defp simulate_reflex_only(events) do
    init = %{pred: Predictor.new(), ctx: -1, ok: 0, n: 0}

    f =
      events
      |> Enum.with_index()
      |> Enum.reduce(init, fn {{e, _}, t}, st ->
        ok = if e in Predictor.top(st.pred, st.ctx, t, Cfg.top_m()), do: 1, else: 0
        %{st | pred: Predictor.update(st.pred, st.ctx, e, t), ctx: e, ok: st.ok + ok, n: st.n + 1}
      end)

    %{quality: f.ok / f.n, cost: Cfg.cost_reflex(), esc_rate: 0.0}
  end

  defp simulate_cache(events) do
    init = %{
      pred: Predictor.new(), handlers: %{}, ctx: -1, cost: 0.0, esc: 0, n: 0,
      since_switch: 9999, post: [], steady: [], costs: []
    }

    f =
      events
      |> Enum.with_index()
      |> Enum.reduce(init, fn {{e, sw}, t}, st ->
        key = {st.ctx, e}
        handlers = st.handlers |> Enum.reject(fn {_, last} -> t - last > handler_ttl() end) |> Map.new()
        hit = Map.has_key?(handlers, key)

        {cost, handlers, esc} =
          if hit,
            do: {Cfg.cost_reflex(), Map.put(handlers, key, t), 0},
            else: {Cfg.cost_cortex(), Map.put(handlers, key, t), 1}

        # surprise channel (attention, not cost)
        s = -:math.log2(Predictor.p(st.pred, st.ctx, e, t))
        anomaly = if s > Cfg.anomaly_theta(), do: 1, else: 0
        since = if sw, do: 0, else: st.since_switch + 1

        %{
          st
          | pred: Predictor.update(st.pred, st.ctx, e, t),
            handlers: handlers,
            ctx: e,
            cost: st.cost + cost,
            esc: st.esc + esc,
            n: st.n + 1,
            since_switch: since,
            post: if(since < 60, do: [anomaly | st.post], else: st.post),
            steady: if(since >= 200, do: [anomaly | st.steady], else: st.steady),
            costs: [cost | st.costs]
        }
      end)

    curve =
      f.costs
      |> Enum.reverse()
      |> Enum.chunk_every(5000)
      |> Enum.map(&(Enum.sum(&1) / length(&1)))

    %{
      quality: 1.0,
      cost: f.cost / f.n,
      esc_rate: f.esc / f.n,
      curve: curve,
      handlers: map_size(f.handlers),
      post_switch: avg(f.post),
      steady: avg(f.steady)
    }
  end

  defp avg([]), do: 0.0
  defp avg(l), do: Enum.sum(l) / length(l)

  defp row(name, r) do
    IO.puts(
      String.pad_trailing(name, 26) <>
        String.pad_trailing(fmt(r.quality), 10) <>
        String.pad_trailing(fmt2(r.cost), 10) <>
        String.pad_trailing(fmt(r.cost / Cfg.cost_cortex()), 11) <>
        fmt(r.esc_rate)
    )
  end

  defp fmt(x), do: :io_lib.format("~.3f", [x * 1.0]) |> to_string()
  defp fmt2(x), do: :io_lib.format("~.2f", [x * 1.0]) |> to_string()
end

Run.main()

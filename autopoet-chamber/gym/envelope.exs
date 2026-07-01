# E3 — the PINNED drift detector's operating envelope, as a measured fact.
# Matrix: drift severity (fraction of latent tasks replaced) × drift shape (abrupt vs
# gradual) × 3 seeds. For every cell: false alarms in the stationary half (post-warmup)
# and detection latency after the (first) true change.
#
# The pinned detector (from the gym sweep + replay floor lesson):
#   EMA fast(0.02)/slow(0.002) ratio > 1.10 sustained 15 events AND fast > 1.0 bit.
#
# Output is the envelope: "detects drift >= X severity within N events; misses below" —
# a fact about the instrument, so production alarms can be interpreted honestly.
#
# Run:  elixir envelope.exs   (pure simulation — the gym already proved sim==bus here)

defmodule Env.World do
  def n_docs, do: 40
  def n_tasks, do: 8
  def path_len, do: 5

  def gen_tasks(n), do: for(_ <- 1..n, do: Enum.take_random(0..(n_docs() - 1), path_len()))

  # Build a stream of `total` doc accesses; drift begins at `drift_at`.
  # :abrupt — replaced tasks swap at once; :gradual — one task swaps every `stagger` events.
  def stream(total, drift_at, severity, shape) do
    pre = gen_tasks(n_tasks())
    n_swap = max(round(severity * n_tasks()), 1)
    swaps = gen_tasks(n_swap)
    stagger = if shape == :gradual, do: div(2000, n_swap), else: 0

    tasks_at = fn t ->
      swapped =
        cond do
          t < drift_at -> 0
          shape == :abrupt -> n_swap
          true -> min(div(t - drift_at, max(stagger, 1)) + 1, n_swap)
        end

      Enum.take(swaps, swapped) ++ Enum.drop(pre, swapped)
    end

    gen(tasks_at, 0, total, [])
  end

  defp gen(_tasks_at, t, total, acc) when t >= total, do: acc |> Enum.reverse() |> Enum.take(total)

  defp gen(tasks_at, t, total, acc) do
    path = tasks_at.(t) |> Enum.random()

    walk =
      Enum.flat_map(path, fn d ->
        if :rand.uniform() < 0.10, do: [:rand.uniform(n_docs()) - 1], else: [d]
      end)

    gen(tasks_at, t + length(walk), total, Enum.reverse(walk) ++ acc)
  end
end

defmodule Env.Detect do
  def surprises(stream) do
    {ss, _} =
      stream
      |> Enum.with_index()
      |> Enum.reduce({[], {%{}, -1}}, fn {x, t}, {ss, {model, prev}} ->
        {counts, total, tl} = Map.get(model, prev, {%{}, 0.0, t})
        d = :math.pow(0.995, t - tl)
        p = (Map.get(counts, x, 0.0) * d + 0.5) / (total * d + 0.5 * Env.World.n_docs())
        counts = Map.new(counts, fn {k, c} -> {k, c * d} end) |> Map.update(x, 1.0, &(&1 + 1.0))
        {[-:math.log2(p) | ss], {Map.put(model, prev, {counts, total * d + 1.0, t}), x}}
      end)

    Enum.reverse(ss)
  end

  # THE pinned detector — identical constants to replay.exs.
  def alarms(xs) do
    {alarms, _} =
      xs
      |> Enum.with_index()
      |> Enum.reduce({[], {nil, nil, 0}}, fn {x, i}, {alarms, {f, s, run}} ->
        f = if f, do: f + 0.02 * (x - f), else: x
        s = if s, do: s + 0.002 * (x - s), else: x
        run = if f > 1.10 * s and f > 1.0, do: run + 1, else: 0
        {if(run == 15, do: [i | alarms], else: alarms), {f, s, run}}
      end)

    Enum.reverse(alarms)
  end
end

total = 12_000
drift_at = 6_000
grace = 500

IO.puts("\n=== E3: pinned-detector operating envelope (#{total} events, drift @#{drift_at}, 3 seeds/cell) ===\n")
IO.puts(String.pad_trailing("severity", 10) <> String.pad_trailing("shape", 9) <> String.pad_trailing("max FA", 8) <> "median detection latency")

envelope =
  for severity <- [0.125, 0.25, 0.5, 1.0], shape <- [:abrupt, :gradual] do
    cells =
      for seed <- [7, 77, 777] do
        :rand.seed(:exsss, {seed, trunc(severity * 1000), if(shape == :abrupt, do: 1, else: 2)})
        xs = Env.World.stream(total, drift_at, severity, shape) |> Env.Detect.surprises()
        alarms = Env.Detect.alarms(xs)
        fa = Enum.count(alarms, &(&1 >= grace and &1 < drift_at))
        det = alarms |> Enum.filter(&(&1 >= drift_at)) |> List.first()
        {fa, det && det - drift_at}
      end

    max_fa = cells |> Enum.map(&elem(&1, 0)) |> Enum.max()
    lats = for {_, l} <- cells, l != nil, do: l
    med = if lats == [], do: nil, else: Enum.sort(lats) |> Enum.at(div(length(lats), 2))
    detected = length(lats)

    IO.puts(
      String.pad_trailing("#{trunc(severity * 100)}%", 10) <>
        String.pad_trailing(to_string(shape), 9) <>
        String.pad_trailing(to_string(max_fa), 8) <>
        if(med, do: "#{med} events (#{detected}/3 seeds)", else: "MISSED (0/3 seeds)")
    )

    {severity, shape, max_fa, med, detected}
  end

detected_cells = for {s, sh, _, med, n} <- envelope, med != nil and n >= 2, do: {s, sh}
missed_cells = for {s, sh, _, med, n} <- envelope, med == nil or n < 2, do: {s, sh}

IO.puts("""

ENVELOPE (fact): reliably detected (>=2/3 seeds): #{inspect(detected_cells)}
                 missed/unreliable:               #{inspect(missed_cells)}
False-alarm discipline held everywhere max FA above is 0.
Production reading: alarms mean "workload changed at least this much"; silence does NOT
certify stability below the envelope floor.
""")

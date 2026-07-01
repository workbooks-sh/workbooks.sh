# The Nexus Gym — first REALISTIC test of the Autopoiesis v3 learning layer.
#
# Everything below the traffic generator is PRODUCTION CODE, not simulation:
#   * corpus docs are real .work files parsed by Nexus.Literate.parse/1
#   * hooks come from a real .work file compiled by Nexus.Hook.compile/1
#   * every access is a real Nexus.Events.emit/2 — real stamping (id/at/depth), real
#     hook matching, real Task.Supervisor effect dispatch, real subscriber broadcast
#   * the shadow learners consume the events the BUS delivered, not the generator's intent
#
# What it validates on top (all shadow — no actuators, nothing merged):
#   1. COLD START: Hebbian learner initialized from AUTHORED structure (the docs' own
#      [[backlinks]], harvested by the real parser) vs blank-slate vs static-only.
#      Claim: the document is the prior — warm from birth, adaptive after drift.
#   2. PLASTICITY on real bus traffic (same KPIs as spike 1).
#   3. OBJECTIVE DRIFT: two pre-registered detectors on the predictor's own surprise
#      stream — fast/slow EMA ratio and Page-Hinkley. Metrics: false alarms during the
#      stationary half (must be 0), detection latency after the true drift point.
#   4. DISPATCH SETTLEMENT: hook->effect latency through the real supervised-task path.
#
# Run:  cd nexus && mix run --no-start ../autopoet-chamber/gym/run_gym.exs
# Deterministic seed. Writes gym/trace.etf (term_to_binary of the delivered events)
# so any future learner can replay this exact trace.

:rand.seed(:exsss, {11, 22, 33})

defmodule Gym.Cfg do
  def n_docs, do: 40
  def n_tasks, do: 8
  def path_len, do: 5
  def total_events, do: 8_000
  def drift_at, do: 4_000
  def p_noise, do: 0.10
  def p_incident, do: 0.01
  def topk, do: 3
  def eta, do: 0.35
  def decay, do: 0.9985
  def prior_w, do: 0.25
  def spread_beta, do: 0.4
end

defmodule Gym.Corpus do
  # Real .work docs whose PROSE backlinks encode the pre-drift task structure (plus
  # distractor links) — the authored graph a fresh nexus is born with.
  def build(dir, tasks_pre) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    succ =
      tasks_pre
      |> Enum.flat_map(fn path -> Enum.zip(path, tl(path)) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    for d <- 0..(Gym.Cfg.n_docs() - 1) do
      links = Map.get(succ, d, []) |> Enum.uniq()
      distractors = for _ <- 1..2, do: :rand.uniform(Gym.Cfg.n_docs()) - 1
      refs = (links ++ distractors) |> Enum.uniq() |> Enum.map_join(" and ", &"[[doc-#{&1}]]")

      File.write!(Path.join(dir, "doc-#{d}.work"), """
      # Doc #{d}

      Working notes for step #{d}. Continue with #{refs}. Tagged #gym.
      """)
    end

    dir
  end

  # Harvest the authored prior through the REAL parser: doc -> linked doc edges.
  def prior_edges(dir) do
    for f <- Path.wildcard(Path.join(dir, "doc-*.work")),
        src = doc_id(Path.basename(f, ".work")),
        node <- Nexus.Literate.parse(File.read!(f)),
        ref <- Map.get(node, :refs, []),
        dst = backlink_target(ref),
        dst != nil,
        into: MapSet.new() do
      {src, dst}
    end
  end

  defp doc_id("doc-" <> n), do: String.to_integer(n)
  defp backlink_target("[[doc-" <> rest), do: rest |> String.trim_trailing("]]") |> String.to_integer()
  defp backlink_target(_), do: nil
end

defmodule Gym.Learner do
  # Spike-1 machinery, parameterized by {plastic?, decay?, prior}. Edges: %{src => %{dst => {w, t}}}.
  def new(opts) do
    prior =
      for {a, b} <- Keyword.get(opts, :prior, []), reduce: %{} do
        acc -> Map.update(acc, a, %{b => {Gym.Cfg.prior_w(), 0}}, &Map.put(&1, b, {Gym.Cfg.prior_w(), 0}))
      end

    %{g: prior, plastic?: Keyword.get(opts, :plastic?, true), decay?: Keyword.get(opts, :decay?, true)}
  end

  defp eff(w, tl, t, true), do: w * :math.pow(Gym.Cfg.decay(), t - tl)

  def bump(%{plastic?: false} = st, _a, _b, _t), do: st

  def bump(%{decay?: true} = st, a, b, t) do
    edges = Map.get(st.g, a, %{})
    {w0, tl} = Map.get(edges, b, {0.0, t})
    w = eff(w0, tl, t, true)
    %{st | g: Map.put(st.g, a, Map.put(edges, b, {w + Gym.Cfg.eta() * (1.0 - w), t}))}
  end

  def bump(%{decay?: false} = st, a, b, t) do
    edges = Map.get(st.g, a, %{})
    {w0, _} = Map.get(edges, b, {0.0, t})
    %{st | g: Map.put(st.g, a, Map.put(edges, b, {w0 + 1.0, t}))}
  end

  defp out(st, a, t) do
    edges = Map.get(st.g, a, %{})

    if st.decay? do
      for {dst, {w, tl}} <- edges, into: %{}, do: {dst, eff(w, tl, t, true)}
    else
      total = edges |> Enum.map(fn {_, {w, _}} -> w end) |> Enum.sum() |> max(1.0)
      for {dst, {w, _}} <- edges, into: %{}, do: {dst, w / total}
    end
  end

  def predict(st, trace, t) do
    one =
      trace
      |> Enum.zip([1.0, 0.45, 0.2])
      |> Enum.reduce(%{}, fn {doc, act}, acc ->
        Enum.reduce(out(st, doc, t), acc, fn {dst, w}, a -> Map.update(a, dst, act * w, &(&1 + act * w)) end)
      end)

    scores =
      case trace do
        [cur | _] ->
          Enum.reduce(out(st, cur, t), one, fn {mid, w1}, acc ->
            Enum.reduce(out(st, mid, t), acc, fn {dst, w2}, a ->
              Map.update(a, dst, Gym.Cfg.spread_beta() * w1 * w2, &(&1 + Gym.Cfg.spread_beta() * w1 * w2))
            end)
          end)

        [] ->
          one
      end

    scores |> Enum.sort_by(fn {_, s} -> -s end) |> Enum.take(Gym.Cfg.topk()) |> Enum.map(&elem(&1, 0))
  end
end

defmodule Gym.Drift do
  # Pre-registered detectors over the predictor's own surprise stream. No labels, no vibes.
  # EMA-ratio: alarm while fast/slow > ratio for `sustain` consecutive events.
  # Page-Hinkley: alarm when m_t - min(m) > lambda (delta-insensitive drift magnitude).
  def ema_alarms(xs, a_fast \\ 0.02, a_slow \\ 0.002, ratio \\ 1.30, sustain \\ 25) do
    {alarms, _} =
      xs
      |> Enum.with_index()
      |> Enum.reduce({[], {nil, nil, 0}}, fn {x, i}, {alarms, {f, s, run}} ->
        f = if f, do: f + a_fast * (x - f), else: x
        s = if s, do: s + a_slow * (x - s), else: x
        run = if f > ratio * s, do: run + 1, else: 0
        alarms = if run == sustain, do: [i | alarms], else: alarms
        {alarms, {f, s, run}}
      end)

    Enum.reverse(alarms)
  end

  def ph_alarms(xs, delta \\ 0.05, lambda \\ 25.0) do
    {alarms, _} =
      xs
      |> Enum.with_index()
      |> Enum.reduce({[], {0.0, 0.0, 0.0, 0}}, fn {x, i}, {alarms, {mean, m, mmin, n}} ->
        n = n + 1
        mean = mean + (x - mean) / n
        m = m + (x - mean - delta)
        mmin = min(mmin, m)

        if m - mmin > lambda do
          {[i | alarms], {0.0, 0.0, 0.0, 0}}
        else
          {alarms, {mean, m, mmin, n}}
        end
      end)

    Enum.reverse(alarms)
  end
end

defmodule Gym.Main do
  def run do
    dir = Path.expand("gym_corpus", System.tmp_dir!())
    tasks_pre = gen_tasks()
    tasks_post = Enum.take(tasks_pre, div(Gym.Cfg.n_tasks(), 2)) ++ gen_tasks(div(Gym.Cfg.n_tasks(), 2))

    IO.puts("\n=== NEXUS GYM — realistic shadow test through production paths ===\n")

    # ── real corpus + real parser prior ──
    Gym.Corpus.build(dir, tasks_pre)
    prior = Gym.Corpus.prior_edges(dir)
    IO.puts("corpus: #{Gym.Cfg.n_docs()} real .work docs; authored prior edges harvested by Nexus.Literate: #{MapSet.size(prior)}")

    # ── real bus + real hooks + probe effect ──
    {:ok, _sup} = Supervisor.start_link(Nexus.Events.child_specs(), strategy: :one_for_one)
    :ets.new(:gym_probe, [:named_table, :public, :duplicate_bag])

    Nexus.Effects.register("gym_probe", fn _args, ev, _ctx ->
      :ets.insert(:gym_probe, {:settle, ev[:id], System.monotonic_time(:microsecond) - ev[:t0]})
    end)

    hooks =
      Path.expand("gym_hooks.work", __DIR__)
      |> File.read!()
      |> Nexus.Literate.parse()
      |> Enum.filter(&(&1.type == :code and &1.kind == "hook"))
      |> Enum.map(&Nexus.Hook.compile/1)

    IO.puts("hooks compiled + registered via Nexus.Hook: #{Enum.map_join(hooks, ", ", & &1.name)}")

    # ── drive real traffic ──
    Nexus.Events.subscribe()
    drive(tasks_pre, tasks_post)
    Process.sleep(300)
    events = drain([])
    accesses = for ev <- events, ev[:kind] == "doc.access", do: ev
    settles = :ets.tab2list(:gym_probe)

    IO.puts("bus delivered: #{length(events)} events (#{length(accesses)} doc.access); effect settlements: #{length(settles)}")
    stamped? = Enum.all?(events, &(is_binary(&1[:id]) and is_integer(&1[:at]) and &1[:depth] == 0))
    IO.puts("runtime stamping intact (id/at/depth on every delivered event): #{stamped?}")

    lat = settles |> Enum.map(fn {:settle, _, us} -> us end) |> Enum.sort()

    if lat != [] do
      IO.puts(
        "hook→effect settlement latency: p50 #{Enum.at(lat, div(length(lat), 2))}µs  " <>
          "p99 #{Enum.at(lat, min(length(lat) - 1, trunc(length(lat) * 0.99)))}µs  max #{List.last(lat)}µs"
      )
    end

    # persist the trace for replay
    File.write!(Path.expand("trace.etf", __DIR__), :erlang.term_to_binary(events))
    IO.puts("trace persisted: gym/trace.etf (#{length(events)} events, replayable)\n")

    # ── shadow learners on the DELIVERED stream ──
    shadow(accesses, prior)

    # ── objective drift detection on the predictor's surprise ──
    drift(accesses)
  end

  defp gen_tasks(n \\ Gym.Cfg.n_tasks()),
    do: for(_ <- 1..n, do: Enum.take_random(0..(Gym.Cfg.n_docs() - 1), Gym.Cfg.path_len()))

  defp drive(pre, post) do
    Enum.reduce_while(Stream.cycle([:s]), 0, fn _, count ->
      if count >= Gym.Cfg.total_events() do
        {:halt, count}
      else
        tasks = if count >= Gym.Cfg.drift_at(), do: post, else: pre
        path = Enum.random(tasks)

        count =
          Enum.reduce(path, count, fn doc, c ->
            doc = if :rand.uniform() < Gym.Cfg.p_noise(), do: :rand.uniform(Gym.Cfg.n_docs()) - 1, else: doc

            Nexus.Events.emit(%{kind: "doc.access", doc: doc, tags: ["edit"], t0: System.monotonic_time(:microsecond)})

            if :rand.uniform() < Gym.Cfg.p_incident() do
              Nexus.Events.emit(%{kind: "incident", tags: ["incident"], t0: System.monotonic_time(:microsecond)})
            end

            c + 1
          end)

        {:cont, count}
      end
    end)
  end

  defp drain(acc) do
    receive do
      {:event, ev} -> drain([ev | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp shadow(accesses, prior) do
    learners = %{
      hebb_prior: Gym.Learner.new(prior: prior, plastic?: true, decay?: true),
      hebb_blank: Gym.Learner.new(prior: [], plastic?: true, decay?: true),
      counts: Gym.Learner.new(prior: [], plastic?: true, decay?: false),
      static_only: Gym.Learner.new(prior: prior, plastic?: false, decay?: false)
    }

    {hits, _} =
      accesses
      |> Enum.with_index()
      |> Enum.reduce({%{hebb_prior: [], hebb_blank: [], counts: [], static_only: []}, {learners, []}}, fn {ev, t},
                                                                                                          {hits, {ls, trace}} ->
        doc = ev[:doc]

        hits =
          if trace == [] do
            hits
          else
            Map.new(hits, fn {k, hs} ->
              pred = Gym.Learner.predict(ls[k], trace, t)
              {k, [{t, if(doc in pred, do: 1, else: 0)} | hs]}
            end)
          end

        ls =
          case trace do
            [prev | _] -> Map.new(ls, fn {k, l} -> {k, Gym.Learner.bump(l, prev, doc, t)} end)
            [] -> ls
          end

        {hits, {ls, [doc | Enum.take(trace, 2) |> Enum.reject(&(&1 == doc))] |> Enum.take(3)}}
      end)
      |> then(fn {hits, st} -> {hits, st} end)

    d = Gym.Cfg.drift_at()
    IO.puts("SHADOW LEARNERS — top-#{Gym.Cfg.topk()} next-access hit rate on the delivered bus stream:")

    IO.puts(
      String.pad_trailing("  learner", 14) <>
        String.pad_trailing("birth(150)", 12) <>
        String.pad_trailing("coldstart", 11) <>
        String.pad_trailing("pre-drift", 11) <>
        String.pad_trailing("post-drift", 12) <> "settled"
    )

    for {name, hs} <- Enum.sort(hits) do
      IO.puts(
        String.pad_trailing("  #{name}", 14) <>
          String.pad_trailing(fmt(rate(hs, 0, 150)), 12) <>
          String.pad_trailing(fmt(rate(hs, 0, 800)), 11) <>
          String.pad_trailing(fmt(rate(hs, d - 3000, d)), 11) <>
          String.pad_trailing(fmt(rate(hs, d, d + 1500)), 12) <>
          fmt(rate(hs, d + 1500, d + 4000))
      )
    end

    IO.puts("""
      READ: hebb_prior warm at birth (authored links = prior synapses) AND adaptive after
      drift; static_only shows what authored structure alone does once usage diverges.
    """)
  end

  defp drift(accesses) do
    # Decayed-count predictor over the doc stream; surprise = -log2 p̂(doc | prev).
    {surprises, _} =
      accesses
      |> Enum.with_index()
      |> Enum.reduce({[], {%{}, -1}}, fn {ev, t}, {ss, {model, prev}} ->
        doc = ev[:doc]
        {counts, total, tl} = Map.get(model, prev, {%{}, 0.0, t})
        dfac = :math.pow(0.995, t - tl)
        p = (Map.get(counts, doc, 0.0) * dfac + 0.5) / (total * dfac + 0.5 * Gym.Cfg.n_docs())
        s = -:math.log2(p)

        counts = Map.new(counts, fn {k, c} -> {k, c * dfac} end) |> Map.update(doc, 1.0, &(&1 + 1.0))
        model = Map.put(model, prev, {counts, total * dfac + 1.0, t})
        {[s | ss], {model, doc}}
      end)

    xs = Enum.reverse(surprises)
    d = Gym.Cfg.drift_at()
    {pre, _post} = Enum.split(xs, d)

    # Parameter sweep ON THE GYM (the tuning arena); the winning config gets PINNED as the
    # pre-registered production setting. Selection rule (committed before looking): zero
    # false alarms in the stationary half (post-warmup), then minimum detection latency.
    grace = 500

    candidates =
      for(ratio <- [1.10, 1.20, 1.30], sustain <- [15, 25],
          do: {"EMA r=#{ratio} n=#{sustain}", Gym.Drift.ema_alarms(xs, 0.02, 0.002, ratio, sustain)}) ++
        for(lambda <- [25.0, 40.0, 60.0], do: {"PH λ=#{trunc(lambda)}", Gym.Drift.ph_alarms(xs, 0.05, lambda)})

    scored =
      for {name, alarms} <- candidates do
        fa = Enum.count(alarms, &(&1 >= grace and &1 < d))
        det = alarms |> Enum.filter(&(&1 >= d)) |> List.first()
        {name, fa, det && det - d}
      end

    IO.puts("DRIFT DETECTOR SWEEP (stationary-half false alarms | detection latency after true drift @#{d}):")

    for {name, fa, lat} <- scored do
      IO.puts("  #{String.pad_trailing(name, 18)} FA=#{fa}  latency=#{if lat, do: "#{lat} ev", else: "MISSED"}")
    end

    pinned = scored |> Enum.filter(fn {_, fa, lat} -> fa == 0 and lat end) |> Enum.min_by(fn {_, _, lat} -> lat end, fn -> nil end)

    case pinned do
      {name, _, lat} -> IO.puts("  PINNED for production: #{name} (0 false alarms, detects in #{lat} events)")
      nil -> IO.puts("  NO CONFIG met the pre-registered bar (0 FA + detection) — drift detection needs rework")
    end

    IO.puts("  (surprise = the predictor's own prequential loss; drift is 'my model got worse' — no labels)")
    IO.puts("  stationary-half mean surprise: #{fmt(Enum.sum(pre) / max(length(pre), 1))} bits")
  end

  defp rate(hs, lo, hi) do
    win = for {t, h} <- hs, t >= lo and t < hi, do: h
    if win == [], do: 0.0, else: Enum.sum(win) / length(win)
  end

  defp fmt(x), do: :io_lib.format("~.3f", [x * 1.0]) |> to_string()
end

Gym.Main.run()

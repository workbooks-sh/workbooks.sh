# Replay harness — rung 3 of the realistic-testing ladder (wb-mdk4.5).
# Runs the shadow learners + the PINNED drift detector over ANY captured trace, so the
# moment a production trace exists this is the whole analysis step:
#
#   cd nexus && mix run --no-start ../autopoet-chamber/gym/replay.exs [trace-file]
#
# Accepts both trace formats:
#   *.etf   — one term: the full event list (what run_gym.exs writes)
#   *.etfs  — framed append-only stream (what capture.exs writes); torn tail skipped
#
# Analyses (prequential, predict-then-observe — nothing here can overfit hindsight):
#   1. doc.access transitions (if present): hebb vs counts, top-3 hit rate over time
#   2. kind-stream surprise (always): decayed-count predictor over event kinds
#   3. PINNED drift detector (EMA-ratio 1.10x15, from the gym sweep) over both surprise
#      streams — alarm positions reported; on unlabeled production traces alarms are
#      leads to investigate, not scores.

defmodule Replay.Load do
  def events(path) do
    bin = File.read!(path)

    if String.ends_with?(path, ".etfs") do
      Stream.unfold(bin, fn
        <<size::32, blob::binary-size(size), rest::binary>> -> {:erlang.binary_to_term(blob), rest}
        _ -> nil
      end)
      |> Enum.to_list()
    else
      :erlang.binary_to_term(bin)
    end
  end
end

defmodule Replay.Hebb do
  @eta 0.35
  @decay 0.9985
  @topk 3

  def run(stream) do
    {hits, _} =
      stream
      |> Enum.with_index()
      |> Enum.reduce({%{hebb: [], counts: []}, {%{hebb: %{}, counts: %{}}, []}}, fn {x, t}, {hits, {gs, trace}} ->
        hits =
          if trace == [] do
            hits
          else
            Map.new(hits, fn {k, hs} ->
              {k, [{t, if(x in predict(gs[k], trace, t, k == :hebb), do: 1, else: 0)} | hs]}
            end)
          end

        gs =
          case trace do
            [prev | _] ->
              %{hebb: bump_hebb(gs.hebb, prev, x, t), counts: bump_count(gs.counts, prev, x)}

            [] ->
              gs
          end

        {hits, {gs, [x | Enum.take(trace, 2) |> Enum.reject(&(&1 == x))] |> Enum.take(3)}}
      end)

    hits
  end

  defp bump_hebb(g, a, b, t) do
    edges = Map.get(g, a, %{})
    {w0, tl} = Map.get(edges, b, {0.0, t})
    w = w0 * :math.pow(@decay, t - tl)
    Map.put(g, a, Map.put(edges, b, {w + @eta * (1.0 - w), t}))
  end

  defp bump_count(g, a, b) do
    edges = Map.get(g, a, %{})
    {w0, _} = Map.get(edges, b, {0.0, 0})
    Map.put(g, a, Map.put(edges, b, {w0 + 1.0, 0}))
  end

  defp out(g, a, t, true) do
    for {dst, {w, tl}} <- Map.get(g, a, %{}), into: %{}, do: {dst, w * :math.pow(@decay, t - tl)}
  end

  defp out(g, a, _t, false) do
    edges = Map.get(g, a, %{})
    total = edges |> Enum.map(fn {_, {w, _}} -> w end) |> Enum.sum() |> max(1.0)
    for {dst, {w, _}} <- edges, into: %{}, do: {dst, w / total}
  end

  defp predict(g, trace, t, decay?) do
    one =
      trace
      |> Enum.zip([1.0, 0.45, 0.2])
      |> Enum.reduce(%{}, fn {node, act}, acc ->
        Enum.reduce(out(g, node, t, decay?), acc, fn {dst, w}, a -> Map.update(a, dst, act * w, &(&1 + act * w)) end)
      end)

    scores =
      case trace do
        [cur | _] ->
          Enum.reduce(out(g, cur, t, decay?), one, fn {mid, w1}, acc ->
            Enum.reduce(out(g, mid, t, decay?), acc, fn {dst, w2}, a ->
              Map.update(a, dst, 0.4 * w1 * w2, &(&1 + 0.4 * w1 * w2))
            end)
          end)

        [] ->
          one
      end

    scores |> Enum.sort_by(fn {_, s} -> -s end) |> Enum.take(@topk) |> Enum.map(&elem(&1, 0))
  end

  def rate(hs, lo, hi) do
    win = for {t, h} <- hs, t >= lo and t < hi, do: h
    if win == [], do: nil, else: Enum.sum(win) / length(win)
  end
end

defmodule Replay.Surprise do
  # Decayed-count conditional model over an arbitrary symbol stream; returns surprises.
  def run(stream, vocab_hint \\ 40) do
    {ss, _} =
      stream
      |> Enum.with_index()
      |> Enum.reduce({[], {%{}, :none}}, fn {x, t}, {ss, {model, prev}} ->
        {counts, total, tl} = Map.get(model, prev, {%{}, 0.0, t})
        d = :math.pow(0.995, t - tl)
        p = (Map.get(counts, x, 0.0) * d + 0.5) / (total * d + 0.5 * vocab_hint)
        counts = Map.new(counts, fn {k, c} -> {k, c * d} end) |> Map.update(x, 1.0, &(&1 + 1.0))
        {[-:math.log2(p) | ss], {Map.put(model, prev, {counts, total * d + 1.0, t}), x}}
      end)

    Enum.reverse(ss)
  end

  # PINNED detector from the gym sweep: EMA fast/slow ratio > 1.10 sustained 15 events,
  # PLUS an absolute floor (fast EMA > 1.0 bit). The floor is a replay-harness lesson:
  # on near-deterministic streams (mean surprise ~0.1 bit) a pure ratio is hypersensitive
  # — any rare symbol multiplies a near-zero baseline. Drift must be both RELATIVE
  # (model got worse than its own past) and MATERIAL (absolute uncertainty is nontrivial).
  def pinned_alarms(xs), do: ema_alarms(xs, 0.02, 0.002, 1.10, 15, 1.0)

  defp ema_alarms(xs, a_fast, a_slow, ratio, sustain, floor) do
    {alarms, _} =
      xs
      |> Enum.with_index()
      |> Enum.reduce({[], {nil, nil, 0}}, fn {x, i}, {alarms, {f, s, run}} ->
        f = if f, do: f + a_fast * (x - f), else: x
        s = if s, do: s + a_slow * (x - s), else: x
        run = if f > ratio * s and f > floor, do: run + 1, else: 0
        {if(run == sustain, do: [i | alarms], else: alarms), {f, s, run}}
      end)

    Enum.reverse(alarms)
  end
end

path =
  case System.argv() do
    [p | _] -> p
    [] -> Path.expand("trace.etf", __DIR__)
  end

events = Replay.Load.events(path)
IO.puts("\n=== replay: #{Path.basename(path)} — #{length(events)} events ===\n")

kinds = Enum.map(events, & &1[:kind])
kind_freq = kinds |> Enum.frequencies() |> Enum.sort_by(fn {_, c} -> -c end)
IO.puts("kinds: " <> Enum.map_join(kind_freq, ", ", fn {k, c} -> "#{k}=#{c}" end))

# 1. doc transitions, if present
docs = for ev <- events, ev[:kind] == "doc.access", not is_nil(ev[:doc]), do: ev[:doc]

if length(docs) > 100 do
  hits = Replay.Hebb.run(docs)
  n = length(docs)
  windows = [{0, 150, "birth"}, {0, 800, "coldstart"}, {div(n, 4), div(n, 2), "Q2"}, {div(n, 2), 3 * div(n, 4), "Q3"}, {3 * div(n, 4), n, "Q4"}]

  IO.puts("\ndoc.access transitions (#{n} events) — top-3 hit rate, prequential:")
  IO.puts("  " <> String.pad_trailing("learner", 9) <> Enum.map_join(windows, "", fn {_, _, l} -> String.pad_trailing(l, 11) end))

  for {name, hs} <- Enum.sort(hits) do
    row =
      Enum.map_join(windows, "", fn {lo, hi, _} ->
        case Replay.Hebb.rate(hs, lo, hi) do
          nil -> String.pad_trailing("-", 11)
          r -> String.pad_trailing(:io_lib.format("~.3f", [r]) |> to_string(), 11)
        end
      end)

    IO.puts("  " <> String.pad_trailing(to_string(name), 9) <> row)
  end

  doc_surprise = Replay.Surprise.run(docs, docs |> Enum.uniq() |> length())
  alarms = Replay.Surprise.pinned_alarms(doc_surprise)
  IO.puts("\npinned drift detector on doc-stream surprise: #{length(alarms)} alarm(s) at #{inspect(Enum.take(alarms, 10))}")
else
  IO.puts("\n(no doc.access stream in this trace — skipping transition analysis)")
end

# 2. kind-stream surprise (works on any trace)
kind_surprise = Replay.Surprise.run(kinds, kind_freq |> length() |> max(10))
kalarms = Replay.Surprise.pinned_alarms(kind_surprise)
mean_s = Enum.sum(kind_surprise) / max(length(kind_surprise), 1)

IO.puts("kind-stream: mean surprise #{Float.round(mean_s, 3)} bits; pinned detector alarms: #{length(kalarms)} at #{inspect(Enum.take(kalarms, 10))}")
IO.puts("(on unlabeled production traces, alarms are investigation leads, not scores)\n")

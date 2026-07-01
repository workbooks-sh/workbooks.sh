# E4 — scale facts on THIS laptop (the 12-core cloud box only improves them).
#   1. Real bus throughput with 500 registered hooks (linear-scan matching is the
#      known design; measure what it actually costs) vs 0 hooks.
#   2. Hebbian learner update+predict cost on the REAL repo-history graph scale
#      (~16k nodes from E1) + graph memory footprint.
#   3. Capture (framed trace) write throughput.
#
# Run:  cd nexus && mix run --no-start ../autopoet-chamber/gym/bench.exs

{:ok, _} = Supervisor.start_link(Nexus.Events.child_specs(), strategy: :one_for_one)
:rand.seed(:exsss, {4, 4, 4})

# ── 1. bus throughput vs hook count ──────────────────────────────────────────
cnt = :counters.new(1, [:write_concurrency])
Nexus.Effects.register("bench_probe", fn _a, _e, _c -> :counters.add(cnt, 1, 1) end)

bench_emit = fn n ->
  t0 = System.monotonic_time(:microsecond)
  for i <- 1..n, do: Nexus.Events.emit(%{kind: "bench", tags: ["t#{rem(i, 500)}"]})
  System.monotonic_time(:microsecond) - t0
end

n = 5_000
us0 = bench_emit.(n)

for i <- 0..499 do
  Nexus.Hook.register(%{name: "bench_hook_#{i}", match: %{tags: ["t#{i}"]}, trigger: nil, effects: [%{name: "bench_probe", args: %{}}]})
end

us500 = bench_emit.(n)
Process.sleep(300)
settled = :counters.get(cnt, 1)

IO.puts("\n=== E4: scale facts ===\n")
IO.puts("bus emit throughput (#{n} events):")
IO.puts("  0 hooks:   #{trunc(n / (us0 / 1_000_000))} events/s (#{Float.round(us0 / n, 1)} µs/event)")
IO.puts("  500 hooks: #{trunc(n / (us500 / 1_000_000))} events/s (#{Float.round(us500 / n, 1)} µs/event, linear-scan matching + task dispatch)")
IO.puts("  effects settled: #{settled}/#{n}")

# ── 2. learner at real graph scale ───────────────────────────────────────────
root = Path.expand("../..", __DIR__)

{out, 0} =
  System.cmd("git", ["-C", root, "log", "--reverse", "--name-only", "--pretty=format:@@C@@", "-n", "4000"], stderr_to_stdout: true)

stream =
  out
  |> String.split("\n", trim: true)
  |> Enum.reject(&(&1 == "@@C@@" or String.contains?(&1, ".nexus/")))

eta = 0.35
decay = 0.9985

bump = fn g, a, b, t ->
  edges = Map.get(g, a, %{})
  {w0, tl} = Map.get(edges, b, {0.0, t})
  w = w0 * :math.pow(decay, t - tl)
  Map.put(g, a, Map.put(edges, b, {w + eta * (1.0 - w), t}))
end

predict = fn g, trace, t ->
  trace
  |> Enum.zip([1.0, 0.45, 0.2])
  |> Enum.reduce(%{}, fn {node, act}, acc ->
    Map.get(g, node, %{})
    |> Enum.reduce(acc, fn {dst, {w, tl}}, a ->
      Map.update(a, dst, act * w * :math.pow(decay, t - tl), &(&1 + act * w * :math.pow(decay, t - tl)))
    end)
  end)
  |> Enum.sort_by(fn {_, s} -> -s end)
  |> Enum.take(3)
end

t0 = System.monotonic_time(:microsecond)

{graph, _, _} =
  stream
  |> Enum.with_index()
  |> Enum.reduce({%{}, [], 0}, fn {f, t}, {g, trace, _} ->
    _ = if trace != [], do: predict.(g, trace, t)
    g = case trace do
      [prev | _] -> bump.(g, prev, f, t)
      [] -> g
    end

    {g, [f | Enum.take(trace, 2)] |> Enum.take(3), t}
  end)

us_learn = System.monotonic_time(:microsecond) - t0
words = :erts_debug.flat_size(graph)

IO.puts("\nlearner at real scale (#{length(stream)} events, #{map_size(graph)} source nodes):")
IO.puts("  predict+update: #{Float.round(us_learn / length(stream), 1)} µs/event (#{trunc(length(stream) / (us_learn / 1_000_000))} events/s single-process)")
IO.puts("  graph memory: #{Float.round(words * 8 / 1_048_576, 1)} MB")

# ── 3. capture write throughput ──────────────────────────────────────────────
path = Path.join(System.tmp_dir!(), "bench_trace.etfs")
File.rm(path)
{:ok, io} = File.open(path, [:append, :binary, :raw])
ev = %{kind: "doc.access", doc: 17, tags: ["edit"], id: "abc123xyz", at: 1_751_400_000, depth: 0}

nw = 50_000
t0 = System.monotonic_time(:microsecond)

for _ <- 1..nw do
  blob = :erlang.term_to_binary(ev)
  :ok = :file.write(io, <<byte_size(blob)::32, blob::binary>>)
end

us_w = System.monotonic_time(:microsecond) - t0
File.close(io)
sz = File.stat!(path).size
File.rm(path)

IO.puts("\ncapture write: #{trunc(nw / (us_w / 1_000_000))} events/s (#{Float.round(sz / 1_048_576 / (us_w / 1_000_000), 1)} MB/s)")

IO.puts("""

HEADROOM vs a 1,000 events/s production bus (generous for a single nexus):
  bus+500 hooks: #{Float.round(n / (us500 / 1_000_000) / 1000, 1)}x   learner: #{Float.round(length(stream) / (us_learn / 1_000_000) / 1000, 1)}x   capture: #{Float.round(nw / (us_w / 1_000_000) / 1000, 1)}x
""")

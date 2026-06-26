# Live-sync engine — DENSITY HARNESS (epic wb-6qfd, G5).
#
# Answers the goal's "full faith" question: how much live sync fits in a Starter-tier (1GB) machine?
# It drives the CORE SHAPE FAN-OUT ENGINE — N subscribers spread across K channels, a publisher fanning
# R rounds (one message per channel per round) — and reports end-to-end delta latency (p50/p99/max),
# delivered vs dropped, and memory per live subscription.
#
#   mix run scripts/sync-density.exs [subscribers] [channels] [rounds]
#   mix run scripts/sync-density.exs 5000 50 20
#
# SCOPE (stated honestly — no silent caps): this measures the in-process engine — the Registry dispatch,
# the per-subscription memory, the message-passing fan-out. It is the floor of the real number. The full
# transport ceiling (a real WebSocket + socket process + TLS per subscriber) is a strictly heavier layer
# that rides ON this engine; the WS-socket harness is the next layer (it reuses these same percentiles).
# A subscriber here = one `Nexus.Shapes.subscribe` process, exactly what each /ws socket holds server-side.

subs = String.to_integer(Enum.at(System.argv(), 0, "5000"))
chans = String.to_integer(Enum.at(System.argv(), 1, "50"))
rounds = String.to_integer(Enum.at(System.argv(), 2, "20"))

# A duplicate-key Registry — the same spec the app supervises (start it if this bare script didn't).
case Registry.start_link(keys: :duplicate, name: Nexus.Shapes.Registry) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

# A bench resource compiled the same way real resources are (channel-scoped, like Message).
mod =
  "resource Bench do\n  channel :text\n  body :text\nend\n"
  |> Nexus.Literate.parse()
  |> Enum.find(&(&1.type == :code))
  |> Nexus.Resource.compile()

tenant = "bench"
channel = fn i -> "c#{rem(i, chans)}" end

parent = self()

mem_before = :erlang.memory(:total)
procs_before = :erlang.system_info(:process_count)

# Spawn N subscriber processes. Each subscribes to the Bench shape scoped to ITS channel, then collects
# the latency of every delta it receives (publisher stamps monotonic µs in the body). After `rounds`
# deltas it reports its latency list back to the parent. This is exactly the server-side shape of a /ws
# client: one process, one filtered subscription, receiving {:shape_delta, _}.
subscribers =
  for i <- 1..subs do
    chan = channel.(i)

    spawn(fn ->
      Nexus.Shapes.subscribe(mod, tenant, fn row -> row.channel == chan end)
      send(parent, :ready)

      lats =
        Enum.reduce(1..rounds, [], fn _, acc ->
          receive do
            {:shape_delta, %{row: row}} ->
              now = System.monotonic_time(:microsecond)
              t0 = String.to_integer(row.body)
              [now - t0 | acc]
          after
            30_000 -> acc
          end
        end)

      send(parent, {:done, lats})
    end)
  end

# Wait for every subscriber to have registered before publishing (else early deltas miss subscribers).
for _ <- 1..subs, do: receive(do: (:ready -> :ok))

mem_subscribed = :erlang.memory(:total)
subs_per_chan = div(subs, chans)
IO.puts("\n⬡ live-sync density — #{subs} subscribers · #{chans} channels (#{subs_per_chan}/chan) · #{rounds} rounds")
IO.puts("  per-subscription memory: #{Float.round((mem_subscribed - mem_before) / subs / 1024, 2)} KB  (#{Float.round((mem_subscribed - mem_before) / 1_048_576, 1)} MB for #{subs} subs)")

# Publish: R rounds, one message per channel per round → every subscriber receives exactly `rounds`
# deltas. The publisher stamps send time so each subscriber measures true end-to-end fan-out latency.
t_pub = System.monotonic_time(:microsecond)

for _r <- 1..rounds, c <- 0..(chans - 1) do
  t0 = System.monotonic_time(:microsecond)
  {:ok, _} = Nexus.Store.create(mod, %{channel: "c#{c}", body: Integer.to_string(t0)}, tenant)
end

pub_us = System.monotonic_time(:microsecond) - t_pub
total_writes = rounds * chans

# Gather every subscriber's latencies.
all_lats =
  for _ <- 1..subs, reduce: [] do
    acc ->
      receive do
        {:done, lats} -> lats ++ acc
      after
        60_000 -> acc
      end
  end

delivered = length(all_lats)
expected = subs * rounds
mem_after = :erlang.memory(:total)

pct = fn sorted, p ->
  case sorted do
    [] -> 0
    _ -> Enum.at(sorted, min(length(sorted) - 1, trunc(length(sorted) * p)))
  end
end

sorted = Enum.sort(all_lats)

IO.puts("  writes: #{total_writes} in #{Float.round(pub_us / 1000, 1)} ms  (#{Float.round(total_writes / (pub_us / 1_000_000), 0)} writes/s, fan-out #{Float.round(delivered / (pub_us / 1_000_000), 0)} deltas/s)")
IO.puts("  delivered: #{delivered}/#{expected} deltas  (dropped #{expected - delivered})")
IO.puts("  delta latency: p50 #{pct.(sorted, 0.50)}µs · p99 #{pct.(sorted, 0.99)}µs · max #{(sorted == [] && 0) || List.last(sorted)}µs")
IO.puts("  total VM memory: #{Float.round(mem_after / 1_048_576, 1)} MB · processes: #{:erlang.system_info(:process_count) - procs_before} added\n")

# Clean exit — reap any stragglers (subscriber procs are done; nothing supervised to stop).
Enum.each(subscribers, fn p -> if Process.alive?(p), do: Process.exit(p, :kill) end)

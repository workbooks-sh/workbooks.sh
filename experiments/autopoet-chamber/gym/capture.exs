# Capture prototype — the bus-to-trace recorder for the production replay corpus
# (wb-mdk4.5). A plain bus subscriber that appends every delivered event to an
# append-only FRAMED trace file (<<size::32, term_to_binary(event)>> per event —
# appendable, crash-tolerant: a torn final frame is skipped on read, unlike a single
# term blob). In production this exact loop runs as a supervised process registered by
# the cloud layer; here it is validated END-TO-END through the real bus:
#
#   emit (real Nexus.Events) -> subscribe -> framed file -> replay.exs reads it back
#
# Run:  cd nexus && mix run --no-start ../autopoet-chamber/gym/capture.exs

:rand.seed(:exsss, {5, 6, 7})

defmodule Gym.Capture do
  def start(path) do
    File.rm(path)
    parent = self()

    pid =
      spawn_link(fn ->
        Nexus.Events.subscribe()
        send(parent, :subscribed)
        {:ok, io} = File.open(path, [:append, :binary, :raw])
        loop(io, 0, parent)
      end)

    receive do: (:subscribed -> :ok)
    pid
  end

  defp loop(io, n, parent) do
    receive do
      {:event, ev} ->
        blob = :erlang.term_to_binary(ev)
        :ok = :file.write(io, <<byte_size(blob)::32, blob::binary>>)
        loop(io, n + 1, parent)

      {:stop, from} ->
        File.close(io)
        send(from, {:captured, n})
    end
  end

  def stop(pid) do
    send(pid, {:stop, self()})
    receive do: ({:captured, n} -> n)
  end
end

# ── validate through the real bus ──
{:ok, _} = Supervisor.start_link(Nexus.Events.child_specs(), strategy: :one_for_one)
path = Path.expand("captured.etfs", __DIR__)
cap = Gym.Capture.start(path)

n_emitted = 2_000

for i <- 1..n_emitted do
  Nexus.Events.emit(%{kind: "doc.access", doc: rem(i * 7, 40), tags: ["edit"]})
end

Process.sleep(100)
n = Gym.Capture.stop(cap)

# read back
frames =
  path
  |> File.read!()
  |> then(fn bin ->
    Stream.unfold(bin, fn
      <<size::32, blob::binary-size(size), rest::binary>> -> {:erlang.binary_to_term(blob), rest}
      _ -> nil
    end)
    |> Enum.to_list()
  end)

ok_roundtrip = length(frames) == n_emitted and Enum.all?(frames, &(is_binary(&1[:id]) and &1[:kind] == "doc.access"))

IO.puts("""

=== capture prototype (framed append-only trace) ===
emitted through real bus: #{n_emitted}
captured to #{Path.basename(path)}: #{n}
frames decoded on read-back: #{length(frames)}
round-trip intact (ids + kinds preserved): #{ok_roundtrip}
byte size: #{File.stat!(path).size} (#{Float.round(File.stat!(path).size / n_emitted, 1)} B/event)
""")

File.rm(path)
if not ok_roundtrip, do: exit({:shutdown, 1})

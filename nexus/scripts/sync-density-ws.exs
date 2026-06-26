# Live-sync engine — REAL-WS DENSITY HARNESS (epic wb-6qfd, G5, the transport ceiling).
#
# Where sync-density.exs measures the in-process fan-out engine, THIS opens N real RFC-6455 WebSocket
# sockets against a real Bandit server — the true cost: a socket process + receive buffers + the WS
# framing per subscriber. The number this prints is the one that rides against the Starter-tier (1GB)
# fly machine for the published "full faith" figure.
#
#   mix run scripts/sync-density-ws.exs [subscribers] [channels] [rounds] [port]
#   mix run scripts/sync-density-ws.exs 1000 20 10
#
# fd note: each subscriber is one socket — raise `ulimit -n` for large N (no silent cap; a connect that
# fails is COUNTED as a failed subscriber and reported, never hidden).

import Bitwise

subs = String.to_integer(Enum.at(System.argv(), 0, "1000"))
chans = String.to_integer(Enum.at(System.argv(), 1, "20"))
rounds = String.to_integer(Enum.at(System.argv(), 2, "10"))
port = String.to_integer(Enum.at(System.argv(), 3, "4096"))

# ── a compact gen_tcp WS client (same protocol as live_chat_sync_test) ───────────────────────────
defmodule WsBench do
  import Bitwise

  def connect(port) do
    {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 5000)
    key = Base.encode64(:crypto.strong_rand_bytes(16))
    req =
      "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: #{key}\r\n\r\n"

    :ok = :gen_tcp.send(s, req)
    :ok = drain_handshake(s)
    s
  end

  defp drain_handshake(s, acc \\ "") do
    {:ok, c} = :gen_tcp.recv(s, 0, 5000)
    acc = acc <> c
    if String.contains?(acc, "\r\n\r\n"), do: :ok, else: drain_handshake(s, acc)
  end

  def send_text(s, payload) do
    len = byte_size(payload)
    mask = :crypto.strong_rand_bytes(4)
    header =
      cond do
        len <= 125 -> <<0x81, 0x80 ||| len>>
        len <= 0xFFFF -> <<0x81, 0x80 ||| 126, len::16>>
        true -> <<0x81, 0x80 ||| 127, len::64>>
      end

    m = :binary.bin_to_list(mask)
    masked = payload |> :binary.bin_to_list() |> Enum.with_index() |> Enum.map(fn {b, i} -> bxor(b, Enum.at(m, rem(i, 4))) end) |> :binary.list_to_bin()
    :gen_tcp.send(s, [header, mask, masked])
  end

  # Read one TEXT frame's payload (skip control frames). Returns binary or :timeout.
  def recv_text(s, timeout) do
    case :gen_tcp.recv(s, 2, timeout) do
      {:ok, <<b0, b1>>} ->
        len0 = b1 &&& 0x7F
        len =
          case len0 do
            126 -> {:ok, <<l::16>>} = :gen_tcp.recv(s, 2, timeout); l
            127 -> {:ok, <<l::64>>} = :gen_tcp.recv(s, 8, timeout); l
            l -> l
          end

        payload = if len > 0, do: (with({:ok, p} <- :gen_tcp.recv(s, len, timeout), do: p)), else: ""
        if (b0 &&& 0x0F) == 0x1, do: payload, else: recv_text(s, timeout)

      _ -> :timeout
    end
  end
end

# ── boot a real server + register a channel-scoped bench shape ────────────────────────────────────
root = Path.join(System.tmp_dir!(), "wsdens-#{:erlang.unique_integer([:positive])}")
File.mkdir_p!(root)
File.write!(Path.join(root, "index.work"), "WS density bench root.\n")
{:ok, _srv} = Nexus.Server.start_link(root: root, port: port)
Process.sleep(300)

mod =
  "resource Bench do\n  channel :text\n  body :text\nend\n"
  |> Nexus.Literate.parse()
  |> Enum.find(&(&1.type == :code))
  |> Nexus.Resource.compile()

Nexus.Shapes.register("bench", mod, :channel)
tenant = Nexus.Store.default_tenant()

parent = self()
mem_before = :erlang.memory(:total)

# Spawn N subscriber CLIENTS: each opens a socket, subscribes to its channel's bench shape, reads its
# init frame, then collects the latency of `rounds` deltas (publisher stamps monotonic µs in body).
clients =
  for i <- 1..subs do
    chan = "c#{rem(i, chans)}"

    spawn(fn ->
      case (try do WsBench.connect(port) catch _, _ -> :error end) do
        :error ->
          send(parent, {:ready, :error})

        s ->
          WsBench.send_text(s, Jason.encode!(%{op: "shape", name: "bench", scope: chan}))
          _init = WsBench.recv_text(s, 10_000)
          send(parent, {:ready, :ok})

          lats =
            Enum.reduce(1..rounds, [], fn _, acc ->
              case WsBench.recv_text(s, 30_000) do
                :timeout -> acc
                payload ->
                  now = System.monotonic_time(:microsecond)
                  case Jason.decode(payload) do
                    {:ok, %{"type" => "shape:delta", "row" => %{"body" => b}}} -> [now - String.to_integer(b) | acc]
                    _ -> acc
                  end
              end
            end)

          :gen_tcp.close(s)
          send(parent, {:done, lats})
      end
    end)
  end

# Wait for every client to finish connecting (ok or error) before publishing.
{ok_subs, err_subs} =
  for _ <- 1..subs, reduce: {0, 0} do
    {ok, err} -> receive do {:ready, :ok} -> {ok + 1, err}; {:ready, :error} -> {ok, err + 1} end
  end

mem_subscribed = :erlang.memory(:total)
IO.puts("\n⬡ live-sync WS density — #{ok_subs} sockets connected (#{err_subs} failed) · #{chans} channels · #{rounds} rounds · port #{port}")
IO.puts("  per-socket memory: #{Float.round((mem_subscribed - mem_before) / max(ok_subs, 1) / 1024, 2)} KB  (#{Float.round((mem_subscribed - mem_before) / 1_048_576, 1)} MB for #{ok_subs} sockets)")

# Publish R rounds, one message per channel per round → every connected socket gets `rounds` deltas.
t_pub = System.monotonic_time(:microsecond)
for _r <- 1..rounds, c <- 0..(chans - 1) do
  t0 = System.monotonic_time(:microsecond)
  {:ok, _} = Nexus.Store.create(mod, %{channel: "c#{c}", body: Integer.to_string(t0)}, tenant)
end
pub_us = System.monotonic_time(:microsecond) - t_pub

all_lats =
  for _ <- 1..subs, reduce: [] do
    acc -> receive do {:done, lats} -> lats ++ acc after 60_000 -> acc end
  end

delivered = length(all_lats)
expected = ok_subs * rounds
sorted = Enum.sort(all_lats)
pct = fn p -> if sorted == [], do: 0, else: Enum.at(sorted, min(length(sorted) - 1, trunc(length(sorted) * p))) end

IO.puts("  writes: #{rounds * chans} in #{Float.round(pub_us / 1000, 1)} ms  (fan-out #{Float.round(delivered / (pub_us / 1_000_000), 0)} deltas/s over real sockets)")
IO.puts("  delivered: #{delivered}/#{expected} deltas  (dropped #{expected - delivered})")
IO.puts("  delta latency: p50 #{pct.(0.50)}µs · p99 #{pct.(0.99)}µs · max #{(sorted == [] && 0) || List.last(sorted)}µs")
IO.puts("  total VM memory: #{Float.round(:erlang.memory(:total) / 1_048_576, 1)} MB\n")

Enum.each(clients, fn p -> if Process.alive?(p), do: Process.exit(p, :kill) end)

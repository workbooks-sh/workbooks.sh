# Live-sync engine — REMOTE density harness (epic wb-6qfd, G5, the PROD number).
#
# Drives a REAL deployed nexus over the public edge: N `wss://` subscribers + an HTTPS publisher hitting
# the real /cloud/chat/send route. Because publisher and subscribers share this one machine's clock, each
# measured latency is the TRUE end-to-end round trip: laptop POST → fly edge → Store.create → shape
# fan-out → wss push → laptop. The publisher is PACED (one round per tick) so the p99 reflects steady
# state, not a burst — the clean number the local co-located harness couldn't give.
#
#   mix run scripts/sync-density-remote.exs <host> [subscribers] [channels] [rounds] [round_ms]
#   mix run scripts/sync-density-remote.exs wb-density-test.fly.dev 500 20 10 50
#
# No auth needed: the target runs single-tenant (route policies short-circuit to allow — authz.ex:66).
# fd note: each subscriber is one TLS socket; a failed connect is COUNTED + reported, never hidden.

import Bitwise
Application.ensure_all_started(:ssl)
Application.ensure_all_started(:inets)

host = Enum.at(System.argv(), 0) || raise("usage: ... <host> [subs] [chans] [rounds] [round_ms]")
subs = String.to_integer(Enum.at(System.argv(), 1, "500"))
chans = String.to_integer(Enum.at(System.argv(), 2, "20"))
rounds = String.to_integer(Enum.at(System.argv(), 3, "10"))
round_ms = String.to_integer(Enum.at(System.argv(), 4, "50"))

hostc = String.to_charlist(host)

defmodule WsTls do
  import Bitwise

  def connect(host, hostc) do
    {:ok, s} = :ssl.connect(hostc, 443, [:binary, active: false, verify: :verify_none, server_name_indication: hostc], 15_000)
    key = Base.encode64(:crypto.strong_rand_bytes(16))
    req =
      "GET /ws HTTP/1.1\r\nHost: #{host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: #{key}\r\n\r\n"

    :ok = :ssl.send(s, req)
    :ok = handshake(s)
    s
  end

  defp handshake(s, acc \\ "") do
    {:ok, c} = :ssl.recv(s, 0, 15_000)
    acc = acc <> c
    if String.contains?(acc, "\r\n\r\n"), do: :ok, else: handshake(s, acc)
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
    :ssl.send(s, [header, mask, masked])
  end

  def recv_text(s, timeout) do
    case :ssl.recv(s, 2, timeout) do
      {:ok, <<b0, b1>>} ->
        len0 = b1 &&& 0x7F
        len =
          case len0 do
            126 -> {:ok, <<l::16>>} = :ssl.recv(s, 2, timeout); l
            127 -> {:ok, <<l::64>>} = :ssl.recv(s, 8, timeout); l
            l -> l
          end

        payload = if len > 0, do: (with({:ok, p} <- :ssl.recv(s, len, timeout), do: p)), else: ""
        if (b0 &&& 0x0F) == 0x1, do: payload, else: recv_text(s, timeout)

      _ -> :timeout
    end
  end
end

# Sanity: is the target healthy?
case :httpc.request(:get, {~c"https://#{host}/health", []}, [{:ssl, [{:verify, :verify_none}]}, {:timeout, 15_000}], []) do
  {:ok, {{_, 200, _}, _, _}} -> IO.puts("✓ #{host}/health 200")
  other -> raise "target not healthy: #{inspect(other)}"
end

parent = self()

# Spawn N wss subscribers. Each connects, subscribes to its channel's "msgs" shape, reads its init, then
# collects the latency of `rounds` deltas (publisher stamps monotonic µs in the message body).
clients =
  for i <- 1..subs do
    chan = "dench#{rem(i, chans)}"

    spawn(fn ->
      case (try do WsTls.connect(host, hostc) catch _, _ -> :error end) do
        :error -> send(parent, {:ready, :error})
        s ->
          WsTls.send_text(s, Jason.encode!(%{op: "shape", name: "msgs", scope: chan}))
          _init = WsTls.recv_text(s, 20_000)
          send(parent, {:ready, :ok})

          lats =
            Enum.reduce(1..rounds, [], fn _, acc ->
              case WsTls.recv_text(s, 60_000) do
                :timeout -> acc
                payload ->
                  now = System.monotonic_time(:microsecond)
                  case Jason.decode(payload) do
                    {:ok, %{"type" => "shape:delta", "row" => %{"body" => b}}} ->
                      case Integer.parse(b) do
                        {t0, _} -> [now - t0 | acc]
                        _ -> acc
                      end
                    _ -> acc
                  end
              end
            end)

          :ssl.close(s)
          send(parent, {:done, lats})
      end
    end)
  end

{ok_subs, err_subs} =
  for _ <- 1..subs, reduce: {0, 0} do
    {ok, err} -> receive do {:ready, :ok} -> {ok + 1, err}; {:ready, :error} -> {ok, err + 1} end
  end

IO.puts("\n⬡ REMOTE live-sync density — #{ok_subs} wss sockets (#{err_subs} failed) · #{chans} channels · #{rounds} rounds · #{round_ms}ms/round")

# Publish, PACED: one round per tick, one HTTPS POST per channel per round, body stamped with send time.
post = fn chan, t0 ->
  :httpc.request(:post,
    {~c"https://#{host}/cloud/chat/send", [], ~c"application/json", Jason.encode!(%{channel: chan, body: Integer.to_string(t0)})},
    [{:ssl, [{:verify, :verify_none}]}, {:timeout, 20_000}], [])
end

t_pub = System.monotonic_time(:microsecond)
for _r <- 1..rounds do
  for c <- 0..(chans - 1) do
    t0 = System.monotonic_time(:microsecond)
    post.("dench#{c}", t0)
  end
  Process.sleep(round_ms)
end
pub_us = System.monotonic_time(:microsecond) - t_pub

all_lats =
  for _ <- 1..subs, reduce: [] do
    acc -> receive do {:done, lats} -> lats ++ acc after 90_000 -> acc end
  end

delivered = length(all_lats)
expected = ok_subs * rounds
sorted = Enum.sort(all_lats)
pct = fn p -> if sorted == [], do: 0, else: Enum.at(sorted, min(length(sorted) - 1, trunc(length(sorted) * p))) end
ms = fn us -> Float.round(us / 1000, 1) end

IO.puts("  delivered: #{delivered}/#{expected} deltas  (dropped #{expected - delivered})")
IO.puts("  e2e latency (laptop→fly→laptop): p50 #{ms.(pct.(0.50))}ms · p95 #{ms.(pct.(0.95))}ms · p99 #{ms.(pct.(0.99))}ms · max #{ms.((sorted == [] && 0) || List.last(sorted))}ms")
IO.puts("  publish wall: #{ms.(pub_us)}ms for #{rounds * chans} sends\n")

Enum.each(clients, fn p -> if Process.alive?(p), do: Process.exit(p, :kill) end)

defmodule Workbooks.TcpServeBrokerTest do
  use ExUnit.Case, async: false
  alias Workbooks.TcpServeBroker

  defp connect_send_recv(port, payload) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 2_000)
    :ok = :gen_tcp.send(sock, payload)
    resp = recv_all(sock, "")
    :gen_tcp.close(sock)
    resp
  end

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 1_500) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, _} -> acc
    end
  end

  test "host-as-TCP-listener brokers request bytes to a guest handler and returns its response (round-trip)" do
    # the handler is the brokered 'guest' logic (bytes -> bytes); here an UPPERCASE transform proves the
    # request reached it and its response came back out over a real TCP connection the HOST owns.
    {:ok, lsock} = TcpServeBroker.start(handler: fn req -> String.upcase(req) end)
    port = TcpServeBroker.port(lsock)
    on_exit(fn -> TcpServeBroker.stop(lsock) end)

    assert connect_send_recv(port, "hello tcp broker") == "HELLO TCP BROKER"
    # a second connection works too (the acceptor keeps serving)
    assert connect_send_recv(port, "again") == "AGAIN"
  end

  test "REQUEST BYTE CAP — a payload over max_request_bytes is refused (connection closed, no response)" do
    {:ok, lsock} = TcpServeBroker.start(handler: fn req -> req end, max_request_bytes: 16)
    port = TcpServeBroker.port(lsock)
    on_exit(fn -> TcpServeBroker.stop(lsock) end)

    # under the cap echoes; over the cap the host closes without echoing (empty response)
    assert connect_send_recv(port, "tiny") == "tiny"
    assert connect_send_recv(port, String.duplicate("x", 100)) == ""
  end

  test "MID-FLIGHT REVOCATION — a revoked serve_id refuses connections; the server keeps listening" do
    sid = "tcpserve-rev-#{System.unique_integer([:positive])}"
    {:ok, lsock} = TcpServeBroker.start(handler: fn req -> req end, serve_id: sid)
    port = TcpServeBroker.port(lsock)
    on_exit(fn -> TcpServeBroker.stop(lsock) end)

    assert connect_send_recv(port, "ping") == "ping"
    :ok = Workbooks.Revocation.revoke(sid)
    # revoked: the connection is accepted then immediately closed -> no response
    assert connect_send_recv(port, "ping") == ""
    :ok = Workbooks.Revocation.unrevoke(sid)
    # server never stopped listening -> serving again after unrevoke
    assert connect_send_recv(port, "ping") == "ping"
  end

  test "PER-CLIENT FLOOD — many rapid connections from one client are rate-limited (the server survives)" do
    sid = "tcpserve-flood-#{System.unique_integer([:positive])}"
    # budget of 3 connections per (server, client-IP) window — the 4th+ are refused
    {:ok, lsock} = TcpServeBroker.start(handler: fn r -> r end, serve_id: sid, rate: {3, 60_000})
    port = TcpServeBroker.port(lsock)
    on_exit(fn -> TcpServeBroker.stop(lsock) end)

    results = for _ <- 1..8, do: connect_send_recv(port, "x")
    served = Enum.count(results, &(&1 == "x"))
    refused = Enum.count(results, &(&1 == ""))
    # at most the budget is served; the rest are refused — the flood is bounded, the server stays up
    assert served <= 3
    assert refused >= 5
  end

  test "SLOWLORIS — a client that stalls is closed by the absolute deadline (not held forever)" do
    # max_request_ms 500: a client that connects and never completes its request is dropped at the deadline.
    {:ok, lsock} = TcpServeBroker.start(handler: fn r -> r end, max_request_ms: 500)
    port = TcpServeBroker.port(lsock)
    on_exit(fn -> TcpServeBroker.stop(lsock) end)

    t0 = System.monotonic_time(:millisecond)
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 2_000)
    # send NOTHING (a stalled/slowloris client); the server must close us at ~500ms, not hang
    resp = recv_all(sock, "")
    elapsed = System.monotonic_time(:millisecond) - t0
    :gen_tcp.close(sock)

    assert resp == ""
    assert elapsed < 3_000, "slowloris must be dropped at the deadline, took #{elapsed}ms"
  end

  test "GLOBAL CONCURRENCY CAP — connections beyond max_concurrent are refused (bounded handler processes)" do
    # a slow handler holds each slot; max_concurrent 2 means only 2 of 5 simultaneous connections are served.
    {:ok, lsock} =
      TcpServeBroker.start(
        handler: fn r -> Process.sleep(1_500); r end,
        max_concurrent: 2,
        rate: {1_000, 60_000}
      )

    port = TcpServeBroker.port(lsock)
    on_exit(fn -> TcpServeBroker.stop(lsock) end)

    results =
      1..5
      |> Task.async_stream(fn _ -> connect_send_recv(port, "c") end, max_concurrency: 5, timeout: 10_000)
      |> Enum.map(fn {:ok, r} -> r end)

    served = Enum.count(results, &(&1 == "c"))
    # at most max_concurrent are in flight at once -> the rest (which arrive while both slots are held) refused
    assert served <= 2
    assert Enum.count(results, &(&1 == "")) >= 3
  end

  @tag :build
  @tag timeout: 300_000
  test "GUEST-BACKED — a real SANDBOXED wasm command serves the TCP request/response (full brokered model)" do
    assert :ok = Workbooks.Pallet.seed_one("coreutils")

    # the handler IS a sandboxed wasm command: `coreutils cat` echoes stdin->stdout. So this TCP server's
    # logic runs entirely inside a fresh isolated wasm instance per connection — the guest never sees the socket.
    {:ok, lsock} = TcpServeBroker.start(handler: TcpServeBroker.command_handler("coreutils", ["cat"]))
    port = TcpServeBroker.port(lsock)
    on_exit(fn -> TcpServeBroker.stop(lsock) end)

    assert connect_send_recv(port, "brokered through a wasm sandbox") == "brokered through a wasm sandbox"
  end
end

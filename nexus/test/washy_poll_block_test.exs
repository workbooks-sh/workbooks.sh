defmodule WashyPollBlockTest do
  @moduledoc """
  TRUE fd-blocking in poll_oneoff (wb-clmb, the WASIX §0-B tail). A poll_oneoff whose only
  subscriptions are socket fd_read (no ready data) must BLOCK (bounded) on the actor mailbox until
  the socket becomes readable — not busy-return 0 events (which made tokio/mio reactors SPIN).

  We drive the host imports through the public `Washy.invoke_host/2` seam with a scratch `:washy_mem`,
  over a real loopback TCP pair: one fd is a connected washy socket; the peer is a plain `:gen_tcp`
  socket in the test, which sends/closes from a Task so the data arrives DURING the block.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy.FdTable

  @poll {"wasi_snapshot_preview1", "poll_oneoff", 0}

  setup do
    mem = :atomics.new(8192, signed: false)
    Process.put(:washy_mem, mem)
    FdTable.reset()
    Process.delete(:washy_sockstate)
    Process.delete(:washy_socknext)
    Process.delete(:washy_stdin)
    %{mem: mem}
  end

  # ── little-endian guest-memory helpers (mirror washy.ex load/store) ─────────────────────────────
  defp put(mem, addr, val, n) do
    for i <- 0..(n - 1) do
      idx = div(addr + i, 8) + 1
      sh = rem(addr + i, 8) * 8
      byte = Bitwise.band(Bitwise.bsr(val, i * 8), 0xFF)
      w = :atomics.get(mem, idx)
      w = Bitwise.bor(Bitwise.band(w, Bitwise.bnot(Bitwise.bsl(0xFF, sh))), Bitwise.bsl(byte, sh))
      :atomics.put(mem, idx, w)
    end
  end

  defp get(mem, addr, n) do
    Enum.reduce(0..(n - 1), 0, fn i, acc ->
      idx = div(addr + i, 8) + 1
      sh = rem(addr + i, 8) * 8
      byte = Bitwise.band(Bitwise.bsr(:atomics.get(mem, idx), sh), 0xFF)
      Bitwise.bor(acc, Bitwise.bsl(byte, i * 8))
    end)
  end

  defp clock_sub(mem, base, userdata, timeout_ns) do
    put(mem, base + 0, userdata, 8)
    put(mem, base + 8, 0, 1)
    put(mem, base + 16, 1, 4)
    put(mem, base + 24, timeout_ns, 8)
    put(mem, base + 32, 0, 8)
    put(mem, base + 40, 0, 2)
  end

  defp fd_sub(mem, base, userdata, tag, fd) do
    put(mem, base + 0, userdata, 8)
    put(mem, base + 8, tag, 1)
    put(mem, base + 16, fd, 4)
  end

  defp read_event(mem, base) do
    %{
      userdata: get(mem, base + 0, 8),
      error: get(mem, base + 8, 2),
      type: get(mem, base + 10, 1),
      nbytes: get(mem, base + 16, 8),
      rwflags: get(mem, base + 24, 2)
    }
  end

  @in_ptr 0
  @out_ptr 512
  @nev_ptr 4096

  defp poll(mem, nsubs) do
    assert Nexus.Washy.invoke_host(@poll, [@in_ptr, @out_ptr, nsubs, @nev_ptr]) == 0
    get(mem, @nev_ptr, 4)
  end

  # Build a real loopback TCP pair and register the SERVER-accepted side as a connected washy socket
  # fd in the FdTable + :washy_sockstate. Returns {washy_fd, peer_client_sock}. The peer is a plain
  # :gen_tcp socket the test drives directly.
  defp tcp_pair do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw])
    {:ok, server} = :gen_tcp.accept(lsock, 1000)
    :gen_tcp.close(lsock)

    # register `server` as a washy connected stream socket (mirror HostSock.accept's state shape).
    Nexus.Washy.HostSock.install()
    state = %{transport: server, kind: :stream, state: :connected, rbuf: "", laddr: nil,
              raddr: nil, backlog: 0, acceptq: []}
    id = Process.get(:washy_socknext, 0)
    Process.put(:washy_socknext, id + 1)
    Process.put(:washy_sockstate, Map.put(Process.get(:washy_sockstate, %{}), id, state))
    fd = FdTable.alloc(%{kind: :socket, ref: id})
    # the washy socket's controlling process must be THIS process (the one running poll) so armed
    # active:once messages land in our mailbox.
    :gen_tcp.controlling_process(server, self())
    {fd, client}
  end

  test "blocks then wakes when peer sends data during the block", %{mem: mem} do
    {fd, client} = tcp_pair()
    fd_sub(mem, @in_ptr, 0xAA, 1, fd)
    # long clock so the block is bounded but won't fire first.
    clock_sub(mem, @in_ptr + 48, 0xBB, 10_000_000_000)

    # send from a Task ~20ms in, so data arrives WHILE poll is blocked.
    Task.start(fn -> Process.sleep(20); :gen_tcp.send(client, "ping") end)

    t0 = System.monotonic_time(:millisecond)
    n = poll(mem, 2)
    elapsed = System.monotonic_time(:millisecond) - t0

    assert n == 1
    ev = read_event(mem, @out_ptr)
    assert ev.userdata == 0xAA
    assert ev.type == 1
    assert ev.error == 0
    assert ev.nbytes > 0
    # proves it BLOCKED (waited for the send), not spun and returned 0.
    assert elapsed >= 15
    :gen_tcp.close(client)
  end

  test "blocked poll wakes on peer close with POLLHUP", %{mem: mem} do
    {fd, client} = tcp_pair()
    fd_sub(mem, @in_ptr, 0xCC, 1, fd)

    Task.start(fn -> Process.sleep(20); :gen_tcp.close(client) end)

    n = poll(mem, 1)

    assert n == 1
    ev = read_event(mem, @out_ptr)
    assert ev.userdata == 0xCC
    assert ev.type == 1
    assert ev.rwflags == 0x0001
    assert ev.nbytes == 0
  end

  test "bounded timeout: idle socket + 50ms clock fires the clock event (no hang)", %{mem: mem} do
    {fd, client} = tcp_pair()
    fd_sub(mem, @in_ptr, 0xD1, 1, fd)
    clock_sub(mem, @in_ptr + 48, 0xD2, 50_000_000)

    t0 = System.monotonic_time(:millisecond)
    n = poll(mem, 2)
    elapsed = System.monotonic_time(:millisecond) - t0

    assert n == 1
    ev = read_event(mem, @out_ptr)
    assert ev.type == 0
    assert ev.userdata == 0xD2
    assert elapsed >= 40
    assert elapsed < 5_000
    :gen_tcp.close(client)
  end

  test "selective receive does not swallow unrelated mailbox messages", %{mem: mem} do
    {fd, client} = tcp_pair()
    # an unrelated message sitting in the mailbox before the poll (e.g. a wb_timer / worker IPC).
    send(self(), {:some_other, 1})

    fd_sub(mem, @in_ptr, 0xE1, 1, fd)
    Task.start(fn -> Process.sleep(20); :gen_tcp.send(client, "x") end)

    n = poll(mem, 1)
    assert n == 1

    # the unrelated message must STILL be in our mailbox (poll only matched armed tcp messages).
    assert_received {:some_other, 1}
    :gen_tcp.close(client)
  end
end

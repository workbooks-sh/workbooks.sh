defmodule WashySockTest do
  @moduledoc """
  WASIX §3 BSD-socket surface (wb-j9op). Drives the `sock_*` host imports through the public
  `Washy.invoke_host/2` seam (the same seam both lanes use) with a scratch `:washy_mem`. Real
  loopback TCP/UDP roundtrips on ephemeral ports + DNS resolve.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy.FdTable

  setup do
    mem = :atomics.new(8192, signed: false)
    Process.put(:washy_mem, mem)
    FdTable.reset()
    Process.delete(:washy_sockstate)
    Process.delete(:washy_socknext)
    %{mem: mem}
  end

  # ── memory helpers (mirror washy.ex load/store) ───────────────────────────────────────────────
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

  defp put_bytes(mem, addr, bin) do
    bin |> :binary.bin_to_list() |> Enum.with_index() |> Enum.each(fn {b, i} -> put(mem, addr + i, b, 1) end)
  end

  # write a __wasi_addr_port_t (ipv4) at `ptr`: tag@0 (INET4=1), port@2, 4 addr bytes @4.
  defp put_addr4(mem, ptr, {a, b, c, d}, port) do
    put(mem, ptr, 1, 1)
    put(mem, ptr + 2, port, 2)
    Enum.with_index([a, b, c, d]) |> Enum.each(fn {byte, i} -> put(mem, ptr + 4 + i, byte, 1) end)
  end

  defp get_addr(mem, ptr) do
    tag = get(mem, ptr, 1)
    port = get(mem, ptr + 2, 2)
    ip = {get(mem, ptr + 4, 1), get(mem, ptr + 5, 1), get(mem, ptr + 6, 1), get(mem, ptr + 7, 1)}
    {tag, ip, port}
  end

  # write an iovec {buf,len} @vptr pointing at data laid at dptr.
  defp put_iovec(mem, vptr, dptr, data) do
    put_bytes(mem, dptr, data)
    put(mem, vptr, dptr, 4)
    put(mem, vptr + 4, byte_size(data), 4)
  end

  defp inv(spec, args), do: Nexus.Washy.invoke_host({"wasi_snapshot_preview1", spec, 0}, args)

  # scratch memory map (well-spaced)
  @addr 64
  @iov 128
  @data 256
  @out 512

  test "TCP full roundtrip: open→bind→listen→accept + connect + send/recv both ways", %{mem: mem} do
    # server: open, bind 127.0.0.1:0, listen
    assert inv("sock_open", [2, 1, 6, @out]) == 0
    srv = get(mem, @out, 4)
    put_addr4(mem, @addr, {127, 0, 0, 1}, 0)
    assert inv("sock_bind", [srv, @addr]) == 0
    assert inv("sock_listen", [srv, 16]) == 0

    # read the assigned ephemeral port
    assert inv("sock_addr_local", [srv, @addr]) == 0
    {_tag, _ip, port} = get_addr(mem, @addr)
    assert port > 0

    # client: open + connect to that port
    assert inv("sock_open", [2, 1, 6, @out + 8]) == 0
    cli = get(mem, @out + 8, 4)
    put_addr4(mem, @addr + 32, {127, 0, 0, 1}, port)
    assert inv("sock_connect", [cli, @addr + 32]) == 0

    # client sends "ping"
    put_iovec(mem, @iov, @data, "ping")
    assert inv("sock_send", [cli, @iov, 1, 0, @out + 16]) == 0
    assert get(mem, @out + 16, 4) == 4

    # server accepts + recvs "ping" (recv iovec @iov+8 → buffer @data+64, cap 16)
    assert inv("sock_accept", [srv, 0, @out + 24, @addr + 64]) == 0
    conn = get(mem, @out + 24, 4)
    Process.sleep(20)
    put(mem, @iov + 8, @data + 64, 4)
    put(mem, @iov + 12, 16, 4)
    assert inv("sock_recv", [conn, @iov + 8, 1, 0, @out + 32, @out + 36]) == 0
    assert read_buf(mem, @data + 64, get(mem, @out + 32, 4)) == "ping"

    # server sends "pong"
    put_iovec(mem, @iov + 16, @data + 32, "pong")
    assert inv("sock_send", [conn, @iov + 16, 1, 0, @out + 40]) == 0
    Process.sleep(20)

    # client recvs "pong" (recv iovec @iov+24 → buffer @data+96, cap 16)
    put(mem, @iov + 24, @data + 96, 4)
    put(mem, @iov + 28, 16, 4)
    assert inv("sock_recv", [cli, @iov + 24, 1, 0, @out + 44, @out + 48]) == 0
    assert read_buf(mem, @data + 96, get(mem, @out + 44, 4)) == "pong"
  end

  defp read_buf(_mem, _ptr, 0), do: ""
  defp read_buf(mem, ptr, n), do: for(i <- 0..(n - 1), do: get(mem, ptr + i, 1)) |> :erlang.list_to_binary()

  test "NONBLOCK sock_recv with no data → EAGAIN(6)", %{mem: mem} do
    {srv, cli, conn, port} = connected_pair(mem)
    _ = {srv, port}
    # mark conn NONBLOCK
    flags = FdTable.get_flags(conn)
    FdTable.set_flags(conn, Bitwise.bor(flags, 0x0004))
    put(mem, @iov, @data, 4)
    put(mem, @iov + 4, 16, 4)
    assert inv("sock_recv", [conn, @iov, 1, 0, @out, @out + 8]) == 6
    _ = cli
  end

  test "peer close → sock_recv returns 0 bytes (EOF)", %{mem: mem} do
    {_srv, cli, conn, _port} = connected_pair(mem)
    # close client → conn sees EOF
    assert inv("sock_shutdown", [cli, 3]) == 0
    FdTable.close(cli)
    put(mem, @iov, @data, 4)
    put(mem, @iov + 4, 16, 4)
    Process.sleep(20)
    assert inv("sock_recv", [conn, @iov, 1, 0, @out, @out + 8]) == 0
    assert get(mem, @out, 4) == 0
  end

  test "poll_oneoff on a connected socket: not-ready, then ready after peer sends", %{mem: mem} do
    {_srv, cli, conn, _port} = connected_pair(mem)

    # subscription for conn fd_read @0; events @600; nevents @700
    fd_sub(mem, 0, 99, 1, conn)
    assert inv("poll_oneoff", [0, 600, 1, 700]) == 0
    assert get(mem, 700, 4) == 0

    # client sends → conn becomes readable
    put_iovec(mem, @iov, @data, "hi")
    assert inv("sock_send", [cli, @iov, 1, 0, @out]) == 0
    Process.sleep(20)

    fd_sub(mem, 0, 99, 1, conn)
    assert inv("poll_oneoff", [0, 600, 1, 700]) == 0
    assert get(mem, 700, 4) == 1
    # event nbytes > 0
    assert get(mem, 600 + 16, 8) > 0
  end

  test "sock_shutdown(write) → peer sees EOF", %{mem: mem} do
    {_srv, cli, conn, _port} = connected_pair(mem)
    assert inv("sock_shutdown", [cli, 2]) == 0
    Process.sleep(20)
    put(mem, @iov, @data, 4)
    put(mem, @iov + 4, 16, 4)
    assert inv("sock_recv", [conn, @iov, 1, 0, @out, @out + 8]) == 0
    assert get(mem, @out, 4) == 0
  end

  test "UDP datagram roundtrip", %{mem: mem} do
    # receiver: open dgram, bind 0
    assert inv("sock_open", [2, 2, 17, @out]) == 0
    rx = get(mem, @out, 4)
    put_addr4(mem, @addr, {127, 0, 0, 1}, 0)
    assert inv("sock_bind", [rx, @addr]) == 0
    assert inv("sock_addr_local", [rx, @addr]) == 0
    {_t, _ip, rport} = get_addr(mem, @addr)
    assert rport > 0

    # sender: open dgram, bind 0, then "connect" (set raddr) to rx, send
    assert inv("sock_open", [2, 2, 17, @out + 8]) == 0
    tx = get(mem, @out + 8, 4)
    put_addr4(mem, @addr + 16, {127, 0, 0, 1}, 0)
    assert inv("sock_bind", [tx, @addr + 16]) == 0
    put_addr4(mem, @addr + 32, {127, 0, 0, 1}, rport)
    assert inv("sock_connect", [tx, @addr + 32]) == 0

    put_iovec(mem, @iov, @data, "dgram!")
    assert inv("sock_send", [tx, @iov, 1, 0, @out + 16]) == 0
    Process.sleep(20)

    put(mem, @iov + 8, @data + 64, 4)
    put(mem, @iov + 12, 32, 4)
    assert inv("sock_recv", [rx, @iov + 8, 1, 0, @out + 24, @out + 28]) == 0
    assert read_buf(mem, @data + 64, get(mem, @out + 24, 4)) == "dgram!"
  end

  test "DNS sock_addr_resolve localhost → at least one addr", %{mem: mem} do
    put_bytes(mem, @data, "localhost")
    assert inv("sock_addr_resolve", [@data, 9, 80, @addr, 8, @out]) == 0
    naddrs = get(mem, @out, 4)
    assert naddrs >= 1
    # first addr decodes to a sane v4/v6 tag (__WASI_ADDRESS_FAMILY_INET4=1 / INET6=2)
    tag = get(mem, @addr, 1)
    assert tag in [1, 2]
  end

  # ── helpers ───────────────────────────────────────────────────────────────────────────────────
  defp fd_sub(mem, base, userdata, tag, fd) do
    put(mem, base + 0, userdata, 8)
    put(mem, base + 8, tag, 1)
    put(mem, base + 16, fd, 4)
  end

  # establish a connected {srv, cli, conn, port}.
  defp connected_pair(mem) do
    assert inv("sock_open", [2, 1, 6, @out]) == 0
    srv = get(mem, @out, 4)
    put_addr4(mem, @addr, {127, 0, 0, 1}, 0)
    assert inv("sock_bind", [srv, @addr]) == 0
    assert inv("sock_listen", [srv, 16]) == 0
    assert inv("sock_addr_local", [srv, @addr]) == 0
    {_t, _ip, port} = get_addr(mem, @addr)

    assert inv("sock_open", [2, 1, 6, @out + 8]) == 0
    cli = get(mem, @out + 8, 4)
    put_addr4(mem, @addr + 32, {127, 0, 0, 1}, port)
    assert inv("sock_connect", [cli, @addr + 32]) == 0

    assert inv("sock_accept", [srv, 0, @out + 24, @addr + 64]) == 0
    conn = get(mem, @out + 24, 4)
    {srv, cli, conn, port}
  end
end

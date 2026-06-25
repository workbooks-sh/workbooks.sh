defmodule WashyPollOneoffTest do
  @moduledoc """
  REAL WASI poll_oneoff (WASIX §0-B, wb-0tu6). We drive the host import directly via the public
  `Washy.invoke_host/2` seam (the same seam the transpiler uses), set up `:washy_mem`, lay down
  subscription bytes, call poll_oneoff, then read back the event records + nevents.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy.FdTable

  @poll {"wasi_snapshot_preview1", "poll_oneoff", 0}

  # one 64KiB wasm page of scratch memory.
  setup do
    mem = :atomics.new(8192, signed: false)
    Process.put(:washy_mem, mem)
    FdTable.reset()
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

  # Write a clock subscription at `base`.
  defp clock_sub(mem, base, userdata, timeout_ns, opts \\ []) do
    put(mem, base + 0, userdata, 8)
    put(mem, base + 8, 0, 1)
    put(mem, base + 16, Keyword.get(opts, :clock_id, 1), 4)
    put(mem, base + 24, timeout_ns, 8)
    put(mem, base + 32, 0, 8)
    put(mem, base + 40, Keyword.get(opts, :flags, 0), 2)
  end

  # Write an fd subscription (tag 1=read, 2=write) at `base`.
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

  # Layout: subscriptions @0, events @512, nevents @4096.
  @in_ptr 0
  @out_ptr 512
  @nev_ptr 4096

  defp poll(mem, nsubs) do
    assert Nexus.Washy.invoke_host(@poll, [@in_ptr, @out_ptr, nsubs, @nev_ptr]) == 0
    get(mem, @nev_ptr, 4)
  end

  test "single relative clock (5ms) returns one clock event after ~the timeout", %{mem: mem} do
    clock_sub(mem, @in_ptr, 0xABCD, 5_000_000)
    t0 = System.monotonic_time(:millisecond)
    n = poll(mem, 1)
    elapsed = System.monotonic_time(:millisecond) - t0

    assert n == 1
    ev = read_event(mem, @out_ptr)
    assert ev.userdata == 0xABCD
    assert ev.error == 0
    assert ev.type == 0
    assert elapsed >= 3
  end

  test "relative clock timeout 0 returns immediately with one event", %{mem: mem} do
    clock_sub(mem, @in_ptr, 7, 0)
    t0 = System.monotonic_time(:millisecond)
    n = poll(mem, 1)
    elapsed = System.monotonic_time(:millisecond) - t0

    assert n == 1
    assert read_event(mem, @out_ptr).type == 0
    assert elapsed < 50
  end

  test "pipe fd_read with buffered bytes is ready immediately (nbytes = available)", %{mem: mem} do
    {rfd, wfd} = FdTable.pipe()
    %{ref: {pid, _}} = FdTable.get(wfd)
    FdTable.Pipe.write(pid, "hello")

    fd_sub(mem, @in_ptr, 1, 1, rfd)
    n = poll(mem, 1)

    assert n == 1
    ev = read_event(mem, @out_ptr)
    assert ev.type == 1
    assert ev.error == 0
    assert ev.nbytes == 5
    assert ev.rwflags == 0
  end

  test "pipe fd_read at EOF (write end closed) is ready with POLLHUP, nbytes 0", %{mem: mem} do
    {rfd, wfd} = FdTable.pipe()
    :ok = FdTable.close(wfd)

    fd_sub(mem, @in_ptr, 2, 1, rfd)
    n = poll(mem, 1)

    assert n == 1
    ev = read_event(mem, @out_ptr)
    assert ev.type == 1
    assert ev.nbytes == 0
    assert ev.rwflags == 0x0001
  end

  test "pipe fd_write is ready immediately", %{mem: mem} do
    {_rfd, wfd} = FdTable.pipe()
    fd_sub(mem, @in_ptr, 3, 2, wfd)
    n = poll(mem, 1)

    assert n == 1
    ev = read_event(mem, @out_ptr)
    assert ev.type == 2
    assert ev.error == 0
    assert ev.nbytes == 65_536
  end

  test "mix: not-ready empty pipe fd_read + clock(5ms) returns the clock event", %{mem: mem} do
    {rfd, _wfd} = FdTable.pipe()
    fd_sub(mem, @in_ptr, 100, 1, rfd)
    clock_sub(mem, @in_ptr + 48, 200, 5_000_000)

    n = poll(mem, 2)

    assert n == 1
    ev = read_event(mem, @out_ptr)
    assert ev.type == 0
    assert ev.userdata == 200
  end

  test "nevents reflects the number of events emitted (multiple ready)", %{mem: mem} do
    {rfd, wfd} = FdTable.pipe()
    %{ref: {pid, _}} = FdTable.get(wfd)
    FdTable.Pipe.write(pid, "ab")

    fd_sub(mem, @in_ptr, 10, 1, rfd)
    fd_sub(mem, @in_ptr + 48, 11, 2, wfd)
    n = poll(mem, 2)

    assert n == 2
    assert read_event(mem, @out_ptr).userdata == 10
    assert read_event(mem, @out_ptr + 32).userdata == 11
  end
end

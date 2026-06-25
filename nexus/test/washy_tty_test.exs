defmodule WashyTtyTest do
  @moduledoc """
  WASIX §4 TTY/termios surface (wb-cudg). Drives `tty_get`/`tty_set` (and the isatty path
  fd_fdstat_get derives from) through the public `Washy.invoke_host/2` seam with a scratch
  `:washy_mem`, plus the `Nexus.Washy.Tty` state home directly.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy.{FdTable, Tty}

  setup do
    mem = :atomics.new(8192, signed: false)
    Process.put(:washy_mem, mem)
    FdTable.reset()
    Process.delete(:washy_tty)
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

  defp inv(spec, args), do: Nexus.Washy.invoke_host({"wasix_32v1", spec, 0}, args)

  # read the __wasi_tty_t at ptr into a map
  defp read_tty(mem, p) do
    %{
      cols: get(mem, p + 0, 4),
      rows: get(mem, p + 4, 4),
      width: get(mem, p + 8, 4),
      height: get(mem, p + 12, 4),
      stdin_tty: get(mem, p + 16, 1),
      stdout_tty: get(mem, p + 17, 1),
      stderr_tty: get(mem, p + 18, 1),
      echo: get(mem, p + 19, 1),
      line_buffered: get(mem, p + 20, 1),
      line_feeds: get(mem, p + 21, 1)
    }
  end

  test "tty_get on defaults: 80x24, detached, echo+line_buffered on", %{mem: mem} do
    assert 0 = inv("tty_get", [0])
    t = read_tty(mem, 0)
    assert t.cols == 80 and t.rows == 24
    assert t.stdin_tty == 0 and t.stdout_tty == 0 and t.stderr_tty == 0
    assert t.echo == 1 and t.line_buffered == 1
  end

  test "attach sets size + all _tty flags, surfaced via tty_get", %{mem: mem} do
    Tty.attach(cols: 120, rows: 40)
    assert 0 = inv("tty_get", [0])
    t = read_tty(mem, 0)
    assert t.cols == 120 and t.rows == 40
    assert t.stdin_tty == 1 and t.stdout_tty == 1 and t.stderr_tty == 1
  end

  test "tty_set raw mode reflects echo/line_buffered/raw; set_raw(false) restores", %{mem: mem} do
    # lay a struct with echo=0, line_buffered=0 (raw)
    put(mem, 0, 100, 4)
    put(mem, 4, 30, 4)
    put(mem, 19, 0, 1)
    put(mem, 20, 0, 1)
    assert 0 = inv("tty_set", [0])

    s = Tty.get()
    assert s.echo == false and s.line_buffered == false and s.raw == true

    Tty.set_raw(false)
    s2 = Tty.get()
    assert s2.echo == true and s2.line_buffered == true and s2.raw == false
  end

  test "isatty?: detached false, attached true, file fd false" do
    refute Tty.isatty?(0)
    refute Tty.isatty?(1)
    refute Tty.isatty?(2)
    Tty.attach([])
    assert Tty.isatty?(0) and Tty.isatty?(1) and Tty.isatty?(2)
    refute Tty.isatty?(5)
  end

  test "fd_fdstat_get on fd 1 after attach reports char device (filetype 2)", %{mem: mem} do
    Tty.attach([])
    assert 0 = inv("fd_fdstat_get", [1, 100])
    assert get(mem, 100, 1) == 2
  end

  test "round-trip: tty_set cols/rows then tty_get returns them", %{mem: mem} do
    put(mem, 0, 200, 4)
    put(mem, 4, 50, 4)
    put(mem, 19, 1, 1)
    put(mem, 20, 1, 1)
    assert 0 = inv("tty_set", [0])
    assert 0 = inv("tty_get", [256])
    t = read_tty(mem, 256)
    assert t.cols == 200 and t.rows == 50
  end
end

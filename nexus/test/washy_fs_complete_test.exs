defmodule WashyFsCompleteTest do
  @moduledoc """
  WASIX §5 filesystem-completeness (wb-wyty): symlinks (create/readlink/follow/loop), ftruncate
  (fd_filestat_set_size), directories (mkdir/rmdir/stat), rename, and unlink. We drive the host imports
  directly via the public `Washy.invoke_host/2` seam (same seam the transpiler uses) over a scratch
  `:washy_mem`, mirroring the poll_oneoff test harness.
  """
  use ExUnit.Case, async: false

  import Bitwise
  alias Nexus.Washy.{FdTable, VFS}

  @snap "wasi_snapshot_preview1"

  setup do
    mem = :atomics.new(8192, signed: false)
    Process.put(:washy_mem, mem)
    Process.put(:washy_backend, :map)
    Process.delete(:washy_vfs)
    Process.delete(:washy_symlinks)
    Process.delete(:washy_dirs)
    FdTable.reset()
    %{mem: mem}
  end

  # ── little-endian guest-memory helpers (mirror washy.ex load/store) ─────────────────────────────
  defp put(mem, addr, val, n) do
    for i <- 0..(n - 1) do
      idx = div(addr + i, 8) + 1
      sh = rem(addr + i, 8) * 8
      byte = band(bsr(val, i * 8), 0xFF)
      w = :atomics.get(mem, idx)
      w = bor(band(w, bnot(bsl(0xFF, sh))), bsl(byte, sh))
      :atomics.put(mem, idx, w)
    end
  end

  defp get(mem, addr, n) do
    Enum.reduce(0..(n - 1), 0, fn i, acc ->
      idx = div(addr + i, 8) + 1
      sh = rem(addr + i, 8) * 8
      bor(acc, bsl(band(bsr(:atomics.get(mem, idx), sh), 0xFF), i * 8))
    end)
  end

  defp put_str(mem, addr, str) do
    for {b, i} <- Enum.with_index(:binary.bin_to_list(str)), do: put(mem, addr + i, b, 1)
    {addr, byte_size(str)}
  end

  defp get_str(mem, addr, len), do: for(i <- 0..(len - 1), into: <<>>, do: <<get(mem, addr + i, 1)>>)

  defp call(name, args), do: Nexus.Washy.invoke_host({@snap, name, 0}, args)

  # ── memory layout ───────────────────────────────────────────────────────────────────────────────
  # scratch regions: paths at 0x100+, stat/out buffers at 0x800+, fd-out at 0x900, bufused at 0x910
  @p1 0x100
  @p2 0x200
  @stat 0x800
  @fdout 0x900
  @bufused 0x910
  @rdbuf 0x920

  defp open(mem, path, oflags, follow) do
    {ptr, len} = put_str(mem, @p1, path)
    lookup = if follow, do: 1, else: 0
    # [dirfd, df(lookupflags), path_ptr, path_len, oflags, rb, ri, ff, ofd_ptr]
    0 = call("path_open", [3, lookup, ptr, len, oflags, 0, 0, 0, @fdout])
    get(mem, @fdout, 4)
  end

  test "symlink → readlink round-trips the target; non-symlink EINVAL; missing ENOENT", %{mem: mem} do
    {op, ol} = put_str(mem, @p1, "real.txt")
    {np, nl} = put_str(mem, @p2, "link")
    # path_symlink(old_ptr, old_len, dirfd, new_ptr, new_len)
    assert call("path_symlink", [op, ol, 3, np, nl]) == 0

    {lp, ll} = put_str(mem, @p1, "link")
    assert call("path_readlink", [3, lp, ll, @rdbuf, 64, @bufused]) == 0
    n = get(mem, @bufused, 4)
    assert get_str(mem, @rdbuf, n) == "real.txt"

    # readlink on a real (non-link) file → EINVAL(28)
    VFS.put("plain.txt", "hi")
    {pp, pl} = put_str(mem, @p1, "plain.txt")
    assert call("path_readlink", [3, pp, pl, @rdbuf, 64, @bufused]) == 28

    # readlink on a missing path → ENOENT(44)
    {mp, ml} = put_str(mem, @p1, "nope.txt")
    assert call("path_readlink", [3, mp, ml, @rdbuf, 64, @bufused]) == 44
  end

  test "open-through-symlink reads the target's content", %{mem: mem} do
    VFS.put("real.txt", "hello-real")
    {op, ol} = put_str(mem, @p1, "real.txt")
    {np, nl} = put_str(mem, @p2, "link")
    assert call("path_symlink", [op, ol, 3, np, nl]) == 0

    fd = open(mem, "link", 0, true)
    assert call("fd_read", [fd, iov(mem, @rdbuf, 64), 1, @bufused]) == 0
    n = get(mem, @bufused, 4)
    assert get_str(mem, @rdbuf, n) == "hello-real"
  end

  test "symlink loop a→b→a → ELOOP, no hang", %{mem: mem} do
    {ap, al} = put_str(mem, @p1, "a")
    {bp, bl} = put_str(mem, @p2, "b")
    assert call("path_symlink", [bp, bl, 3, ap, al]) == 0
    assert call("path_symlink", [ap, al, 3, bp, bl]) == 0

    {p, l} = put_str(mem, @p1, "a")
    assert call("path_open", [3, 1, p, l, 0, 0, 0, 0, @fdout]) == 32
  end

  test "ftruncate shrinks and grows (NUL pad)", %{mem: mem} do
    VFS.put("t.txt", "0123456789")
    fd = open(mem, "t.txt", 0, true)

    assert call("fd_filestat_set_size", [fd, 4]) == 0
    assert VFS.get("t.txt") == "0123"

    assert call("fd_filestat_set_size", [fd, 8]) == 0
    assert VFS.get("t.txt") == "0123" <> <<0, 0, 0, 0>>
  end

  test "mkdir → stat DIRECTORY(3); rmdir non-empty ENOTEMPTY; rmdir empty ok", %{mem: mem} do
    {dp, dl} = put_str(mem, @p1, "mydir")
    assert call("path_create_directory", [3, dp, dl]) == 0

    assert call("path_filestat_get", [3, 1, dp, dl, @stat]) == 0
    assert get(mem, @stat + 16, 1) == 3

    # populate the dir → rmdir must reject ENOTEMPTY(55)
    VFS.put("mydir/child.txt", "x")
    assert call("path_remove_directory", [3, dp, dl]) == 55

    # empty it → rmdir succeeds
    VFS.delete("mydir/child.txt")
    assert call("path_remove_directory", [3, dp, dl]) == 0
    assert call("path_remove_directory", [3, dp, dl]) == 44
  end

  test "rename moves content; unlink removes file and symlink", %{mem: mem} do
    VFS.put("old.txt", "movable")
    {op, ol} = put_str(mem, @p1, "old.txt")
    {np, nl} = put_str(mem, @p2, "new.txt")
    assert call("path_rename", [3, op, ol, 3, np, nl]) == 0
    assert VFS.get("old.txt") == nil
    assert VFS.get("new.txt") == "movable"

    # unlink the moved file
    {up, ul} = put_str(mem, @p1, "new.txt")
    assert call("path_unlink_file", [3, up, ul]) == 0
    assert VFS.get("new.txt") == nil

    # unlink a symlink removes the link (readlink afterwards → ENOENT)
    {tp, tl} = put_str(mem, @p1, "real.txt")
    {lp, ll} = put_str(mem, @p2, "lnk")
    assert call("path_symlink", [tp, tl, 3, lp, ll]) == 0
    {lp2, ll2} = put_str(mem, @p1, "lnk")
    assert call("path_unlink_file", [3, lp2, ll2]) == 0
    assert call("path_readlink", [3, lp2, ll2, @rdbuf, 64, @bufused]) == 44
  end

  # one iovec {buf, len} at scratch addr 0xA00 pointing at `bufaddr`
  defp iov(mem, bufaddr, len) do
    put(mem, 0xA00, bufaddr, 4)
    put(mem, 0xA00 + 4, len, 4)
    0xA00
  end
end

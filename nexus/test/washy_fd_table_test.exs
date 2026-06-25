defmodule WashyFdTableTest do
  use ExUnit.Case, async: false

  alias Nexus.Washy.FdTable
  alias Nexus.Washy.VFS

  setup do
    # fresh unified fd table + virtual FS per test (process-dict scoped).
    Process.delete(:washy_pipes)
    FdTable.reset()
    # clear any VFS keys from a prior test so file fds start clean
    Enum.each(VFS.list(), &VFS.delete/1)
    :ok
  end

  test "stdio + preopen are installed; next user fd is 4" do
    assert %{kind: :file} = FdTable.get(0)
    assert %{kind: :file} = FdTable.get(1)
    assert %{kind: :file} = FdTable.get(2)
    assert %{kind: :dir, ref: "/work"} = FdTable.get(3)
    assert FdTable.alloc(%{kind: :file, ref: "f", pos: 0}) == 4
  end

  test "open a file, write bytes via pos, read them back" do
    VFS.put("greet.txt", "")
    fd = FdTable.alloc(%{kind: :file, ref: "greet.txt", pos: 0})

    # write "hello" by hand the way file_write does (advance pos through the table)
    d = FdTable.get(fd)
    VFS.put("greet.txt", "hello")
    FdTable.put(fd, %{d | pos: 5})

    # rewind, then read
    FdTable.put(fd, %{FdTable.get(fd) | pos: 0})
    %{ref: path, pos: off} = FdTable.get(fd)
    assert binary_part(VFS.get(path), off, 5) == "hello"
  end

  test "dup shares the description: a read through A advances the offset seen by B" do
    VFS.put("d.txt", "abcdef")
    a = FdTable.alloc(%{kind: :file, ref: "d.txt", pos: 0})
    b = FdTable.dup(a)

    refute b == a
    # advance via A
    FdTable.put(a, %{FdTable.get(a) | pos: 3})
    # B sees the same offset (shared description)
    assert FdTable.get(b).pos == 3

    # close A — B still usable (refcount kept the description alive)
    assert FdTable.close(a) == :ok
    assert FdTable.get(a) == nil
    assert FdTable.get(b).pos == 3
  end

  test "dup2: new aliases old; closes new first; old==new is a no-op" do
    a = FdTable.alloc(%{kind: :file, ref: "x", pos: 7})
    # an already-open target fd
    other = FdTable.alloc(%{kind: :file, ref: "y", pos: 99})

    assert FdTable.dup2(a, other) == other
    # `other` now aliases `a`
    assert FdTable.get(other).ref == "x"
    assert FdTable.get(other).pos == 7

    # old == new is a no-op (still valid)
    assert FdTable.dup2(a, a) == a
    assert FdTable.get(a).ref == "x"
  end

  test "fd_close refcount: dup → refs 2; close one keeps resource, close other frees it" do
    a = FdTable.alloc(%{kind: :file, ref: "rc", pos: 0})
    assert FdTable.get(a).refs == 1
    b = FdTable.dup(a)
    assert FdTable.get(a).refs == 2

    assert FdTable.close(a) == :ok
    # description still alive through b, refs back to 1
    assert FdTable.get(b).refs == 1
    assert FdTable.close(b) == :ok
    assert FdTable.get(b) == nil

    # closing a bad fd is EBADF
    assert FdTable.close(999) == {:error, :badf}
  end

  test "set_flags sets O_NONBLOCK and get_flags reflects it" do
    fd = FdTable.alloc(%{kind: :file, ref: "n", pos: 0})
    assert FdTable.get_flags(fd) == 0
    # O_NONBLOCK = 0x0004
    assert FdTable.set_flags(fd, 0x0004) == :ok
    assert FdTable.get_flags(fd) == 0x0004
    assert FdTable.nonblock?(fd)
    assert FdTable.set_flags(999, 0x0004) == {:error, :badf}
  end

  test "pipe: write to write-end, read from read-end; close write-end → EOF" do
    {rfd, wfd} = FdTable.pipe()
    %{ref: {pid, :w}} = FdTable.get(wfd)
    %{ref: {^pid, :r}} = FdTable.get(rfd)

    assert FdTable.Pipe.write(pid, "hello") == 5
    assert FdTable.Pipe.read(pid, 5) == "hello"

    # buffer drained but writer still open → not yet EOF
    refute FdTable.Pipe.eof?(pid)

    # write more, close the write-end, drain → then EOF
    FdTable.Pipe.write(pid, "bye")
    assert FdTable.close(wfd) == :ok
    assert FdTable.Pipe.read(pid, 3) == "bye"
    assert FdTable.Pipe.eof?(pid)
    # subsequent read returns "" (0 bytes = EOF)
    assert FdTable.Pipe.read(pid, 10) == ""
  end

  test "dup clears CLOEXEC on the new fd" do
    a = FdTable.alloc(%{kind: :file, ref: "c", pos: 0})
    assert FdTable.set_cloexec(a, true) == :ok
    assert FdTable.get_cloexec(a) == true
    b = FdTable.dup(a)
    assert FdTable.get_cloexec(b) == false
  end

  test "list enumerates fd → desc pairs" do
    fd = FdTable.alloc(%{kind: :file, ref: "L", pos: 0})
    pairs = FdTable.list()
    assert Enum.any?(pairs, fn {f, d} -> f == fd and d.ref == "L" end)
    # stdio + preopen present
    assert Enum.any?(pairs, fn {f, _} -> f == 3 end)
  end
end

defmodule Nexus.WashyProcTest do
  @moduledoc """
  WASIX §6 process model (wb-yq11): proc_spawn/proc_exec (async subprocess → pid), proc_join/wait
  (exit status), signals (proc_raise/proc_signal/sigaction + default actions + EINTR). Driven against
  the SAME coreutils.wasm program registry the host_exec tests use — a real sub-program to spawn.
  """
  use ExUnit.Case, async: false
  import Bitwise

  alias Nexus.Washy
  alias Nexus.Washy.HostProc

  @sigterm 15

  setup do
    if File.exists?("kits/coreutils.wasm") do
      {:ok, cu} = Washy.decode_cached(File.read!("kits/coreutils.wasm"))
      Process.put(:washy_programs, %{default: cu})
      Process.put(:washy_vfs, %{})
      Process.put(:washy_backend, :map)
      mem = :atomics.new(8192, signed: false)
      Process.put(:washy_mem, mem)

      on_exit(fn ->
        Enum.each(
          [:washy_programs, :washy_vfs, :washy_backend, :washy_out, :washy_argv, :washy_stdin,
           :washy_mem, :washy_procs, :washy_proc_ctr, :washy_pipes, :washy_fdmap, :washy_descs],
          &Process.delete/1
        )
      end)

      {:ok, mem: mem, ok: true}
    else
      {:ok, skip: true}
    end
  end

  # write a NUL/newline-delimited string list at `addr`, return {addr, byte_len}.
  defp put_str(mem, addr, s) do
    Washy.write_bytes(mem, addr, s)
    {addr, byte_size(s)}
  end

  # proc_spawn helper: name + args (list), capture-only stdio, ret pid at ret_ptr.
  defp do_spawn(mem, name, args) do
    {n_ptr, n_len} = put_str(mem, 100, name)
    {a_ptr, a_len} = put_str(mem, 200, Enum.join(args, "\n"))
    ret_ptr = 400
    0 = HostProc.spawn(mem, n_ptr, n_len, a_ptr, a_len, 0, 0, -1, -1, -1, ret_ptr)
    <<pid::little-32>> = Washy.read_bytes(mem, ret_ptr, 4)
    pid
  end

  test "proc_spawn a child that exits 0; proc_join returns exit status (code<<8)", ctx do
    if ctx[:skip], do: :ok, else: (
      mem = ctx.mem
      pid = do_spawn(mem, "true", [])
      assert pid >= 2

      status_ptr = 500
      assert 0 = HostProc.join(mem, pid_ptr(mem, pid), 0, status_ptr)
      <<status::little-32>> = Washy.read_bytes(mem, status_ptr, 4)
      # `true` exits 0 → wait-status = 0 << 8 = 0.
      assert status == 0

      # registry reflects the terminal status.
      assert {:exited, 0} = HostProc.proc(pid).status
    )
  end

  test "proc_spawn `false` → exit 1 reflected as (1<<8) in wait-status", ctx do
    if ctx[:skip], do: :ok, else: (
      mem = ctx.mem
      pid = do_spawn(mem, "false", [])
      status_ptr = 500
      assert 0 = HostProc.join(mem, pid_ptr(mem, pid), 0, status_ptr)
      <<status::little-32>> = Washy.read_bytes(mem, status_ptr, 4)
      assert status == 1 <<< 8
    )
  end

  test "proc_join WNOHANG on a still-running child → no block, EAGAIN/running", ctx do
    if ctx[:skip], do: :ok, else: (
      mem = ctx.mem
      # inject a synthetic still-running child (no worker) so WNOHANG can't race to completion.
      Process.put(:washy_procs, %{
        7 => %{
          os_pid: 7, beam: nil, ref: nil, status: :running, argv: ["sleep"], output: "",
          stdio: {-1, -1, -1}, pending: MapSet.new(), handlers: %{}, mask: MapSet.new()
        }
      })

      # WNOHANG flag = bit 0.
      assert 6 = HostProc.join(mem, pid_ptr(mem, 7), 1, 600)
      assert HostProc.proc(7).status == :running
    )
  end

  test "proc_signal SIGTERM to a child → recorded {:signaled, 15}; join reflects it", ctx do
    if ctx[:skip], do: :ok, else: (
      mem = ctx.mem
      # a never-completing synthetic worker we can terminate.
      worker = spawn(fn -> Process.sleep(60_000) end)
      Process.put(:washy_procs, %{
        8 => %{
          os_pid: 8, beam: worker, ref: nil, status: :running, argv: ["loop"], output: "",
          stdio: {-1, -1, -1}, pending: MapSet.new(), handlers: %{}, mask: MapSet.new()
        }
      })

      assert 0 = HostProc.signal(8, @sigterm)
      assert {:signaled, 15} = HostProc.proc(8).status
      refute Process.alive?(worker)

      status_ptr = 700
      assert 0 = HostProc.join(mem, pid_ptr(mem, 8), 0, status_ptr)
      <<status::little-32>> = Washy.read_bytes(mem, status_ptr, 4)
      # signaled → low 7 bits = sig.
      assert (status &&& 0x7F) == 15
    )
  end

  test "EINTR: a process blocked in proc_join, sent {:wb_signal,_}, returns EINTR (27)", ctx do
    if ctx[:skip], do: :ok, else: (
      parent = self()

      blocker =
        spawn(fn ->
          mem = :atomics.new(1024, signed: false)
          Process.put(:washy_mem, mem)
          # a running child with no worker → join will BLOCK in the bounded receive.
          Process.put(:washy_procs, %{
            9 => %{
              os_pid: 9, beam: nil, ref: nil, status: :running, argv: [], output: "",
              stdio: {-1, -1, -1}, pending: MapSet.new(), handlers: %{}, mask: MapSet.new()
            }
          })
          Washy.write_bytes(mem, 8, <<9::little-32>>)
          rc = HostProc.join(mem, 8, 0, 12)
          send(parent, {:join_rc, rc})
        end)

      # let it enter the receive, then interrupt it.
      Process.sleep(50)
      send(blocker, {:wb_signal, 2})

      assert_receive {:join_rc, 27}, 5_000
    )
  end

  test "sigaction registers a handler (returns 0); oldact captured", ctx do
    if ctx[:skip], do: :ok, else: (
      mem = ctx.mem
      # install handler func idx 42 for SIGTERM; oldact should read back SIG_DFL (0).
      Washy.write_bytes(mem, 800, <<42::little-32>>)
      assert 0 = HostProc.sigaction(mem, @sigterm, 800, 900)
      <<old::little-32>> = Washy.read_bytes(mem, 900, 4)
      assert old == 0

      # re-register SIG_IGN (1); oldact should now read back the previously-installed idx 42.
      Washy.write_bytes(mem, 800, <<1::little-32>>)
      assert 0 = HostProc.sigaction(mem, @sigterm, 800, 900)
      <<old2::little-32>> = Washy.read_bytes(mem, 900, 4)
      assert old2 == 42

      assert HostProc.proc(1).handlers[@sigterm] == :ignore
    )
  end

  test "proc_exec runs an image then the caller exits with its code (washy_exit thrown)", ctx do
    if ctx[:skip], do: :ok, else: (
      mem = ctx.mem
      {n_ptr, n_len} = put_str(mem, 100, "false")
      # exec never returns on success — it throws {:washy_exit, code} (false → 1).
      assert catch_throw(HostProc.exec(mem, n_ptr, n_len, 0, 0, 0, 0, -1)) == {:washy_exit, 1}
    )
  end

  test "pid allocation is monotonic + distinct (starting at 2)", ctx do
    if ctx[:skip], do: :ok, else: (
      mem = ctx.mem
      p1 = do_spawn(mem, "true", [])
      p2 = do_spawn(mem, "true", [])
      p3 = do_spawn(mem, "true", [])
      assert p1 == 2
      assert [p1, p2, p3] == Enum.sort([p1, p2, p3])
      assert length(Enum.uniq([p1, p2, p3])) == 3
    )
  end

  test "proc_fork returns ENOSYS (52) — true fork needs asyncify", ctx do
    if ctx[:skip], do: :ok, else: (
      assert 52 = HostProc.fork(ctx.mem, 0)
    )
  end

  # write a pid into guest memory and return the pointer (proc_join reads the pid from memory).
  defp pid_ptr(mem, pid) do
    Washy.write_bytes(mem, 1000, <<pid::little-32>>)
    1000
  end
end

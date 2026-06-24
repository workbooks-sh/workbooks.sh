defmodule Nexus.WashyTierTest do
  @moduledoc """
  PER-FUNCTION TIERING (research bet F / the end-to-end runner): `Transpile.tier/2` compiles each
  reachable function independently — supported ones become native BEAM, unsupported ones stay on the
  interpreter — and the two lanes interoperate seamlessly over shared `:washy_mem`/`:washy_globals`/fuel.
  The contract: a tiered run is BIT-IDENTICAL to a pure-interpreter run. Proven here by differencing
  `call_io(transpile: true)` against `call_io(transpile: false)`.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy
  alias Nexus.Washy.Transpile

  # Two functions, type (i32)->(i32), plus a 1-page memory:
  #   func0 cold(x):  memory.size; drop; local.get 0          ⇒ returns x, but memory.size is NOT
  #                                                              transpiler-lowerable ⇒ stays interpreted
  #   func1 entry(x): cold(x) + cold(x)                       ⇒ transpiles; calls cold ⇒ trampoline
  # Running `entry` thus exercises: jit-dispatch at the entry (interp→native) AND native→interp
  # trampoline (entry→cold), all sharing one run's state.
  @mixed <<
    0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
    # type: (i32)->(i32)
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7F, 0x01, 0x7F,
    # func: 2 funcs, both type 0
    0x03, 0x03, 0x02, 0x00, 0x00,
    # mem: 1 memory, min 1 page
    0x05, 0x03, 0x01, 0x00, 0x01,
    # export "entry" = func1
    0x07, 0x09, 0x01, 0x05, 0x65, 0x6E, 0x74, 0x72, 0x79, 0x00, 0x01,
    # code: cold = [memory.size, drop, local.get 0] ; entry = [cold(x)+cold(x)]
    0x0A, 0x15, 0x02,
    0x07, 0x00, 0x3F, 0x00, 0x1A, 0x20, 0x00, 0x0B,
    0x0B, 0x00, 0x20, 0x00, 0x10, 0x00, 0x20, 0x00, 0x10, 0x00, 0x6A, 0x0B
  >>

  test "tier/2 transpiles only the supported function, leaving the unsupported one to the interpreter" do
    {:ok, m} = Washy.decode(@mixed)
    {:ok, jit} = Transpile.tier(m, "entry")

    ni = length(m.imports)
    # func1 (entry, global idx ni+1) transpiled; func0 (cold, ni+0) did NOT (memory.size unsupported)
    assert Map.has_key?(jit, ni + 1)
    refute Map.has_key?(jit, ni + 0)
  end

  test "a tiered run is bit-identical to a pure-interpreter run (native entry trampolines into interp cold)" do
    {:ok, m} = Washy.decode(@mixed)

    for x <- [0, 5, 21, 1000, 0xFFFFFFFF] do
      {interp, _} = Washy.call_io(m, "entry", [x], transpile: false)
      {tiered, _} = Washy.call_io(m, "entry", [x], transpile: true)
      assert tiered == interp, "tier diverged at x=#{x}: interp=#{inspect(interp)} tiered=#{inspect(tiered)}"
      # entry(x) = cold(x) + cold(x) = 2x  (mod 2^32)
      assert tiered == Bitwise.band(x + x, 0xFFFFFFFF)
    end
  end

  test "transpile: false leaves the run on the pure interpreter (no jit overhead)" do
    {:ok, m} = Washy.decode(@mixed)
    # sanity: the default lane still works and matches
    assert {10, _} = Washy.call_io(m, "entry", [5], transpile: false)
  end

  describe "real shell module through host_exec (the wb-6c2y regression)" do
    @tag :tmp_dir
    test "a tiered shell pipeline (cat|grep|wc, nested coreutils via host_exec) matches the interpreter" do
      shell = Nexus.Shell.wasm()

      if shell && File.exists?("kits/coreutils.wasm") do
        {:ok, m} = Washy.decode_cached(File.read!(shell))
        {:ok, cu} = Washy.decode_cached(File.read!("kits/coreutils.wasm"))

        run = fn transpile? ->
          Process.put(:washy_backend, :map)
          Process.put(:washy_vfs, %{"a.txt" => "alpha\nbeta\ngamma\n"})
          Process.put(:washy_stdin, "cat /work/a.txt | grep a | wc -l\n")
          Process.put(:washy_argv, ["sh"])
          Process.put(:washy_fds, %{})
          Process.put(:washy_nextfd, 4)
          Process.put(:washy_programs, %{default: cu})

          try do
            {_r, o} = Washy.call_io(m, "_start", [], fuel: 9_000_000_000, transpile: transpile?)
            o
          catch
            :throw, {:washy_exit, _c} -> Process.get(:washy_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
          after
            Enum.each([:washy_vfs, :washy_stdin, :washy_argv, :washy_fds, :washy_nextfd, :washy_programs, :washy_backend], &Process.delete/1)
          end
        end

        # The shell forks coreutils via host_exec; coreutils exits via proc_exit (a throw). Before the
        # context-restore-on-throw fix, the outer transpiled shell resumed with coreutils' globals/pages
        # in the dict → OOB. Tiered output MUST equal the pure-interpreter output (3 lines match 'a').
        assert run.(true) == run.(false)
        assert run.(false) == "3\n"
      else
        IO.puts("\n[skip] shell/coreutils wasm absent")
      end
    end
  end
end

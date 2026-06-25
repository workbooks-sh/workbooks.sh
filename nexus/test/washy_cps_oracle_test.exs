defmodule Nexus.WashyCpsOracleTest do
  @moduledoc """
  **Differential oracle: the reified-stack interpreter ≡ the recursive interpreter (wb-nsrp Stage 1).**

  `tramp`/`interp_invoke_cps` (the fork-safe lane — explicit frames list instead of native BEAM
  recursion, so a continuation is capturable) must be BIT-IDENTICAL to the canonical recursive
  `run/4`. This is the load-bearing gate: true return-twice `proc_fork` (Stage 3) only rides the
  trampoline AFTER it's proven to change nothing about interpreter semantics.

  We prove it the same way the asm lane is proven — run every real wasix `.wasm` fixture under BOTH
  interpreters (pure interp, no JIT, in both) and assert identical exit status + identical stdout
  bytes. The recursive interp is the established correctness oracle, so equality here IS the proof.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy

  @dir Path.join(__DIR__, "conformance/wasix")

  # the same cross-test state hygiene the C-conformance suite uses (shared futex/thread/socket dicts)
  setup do
    for tab <- [:washy_futex, :washy_threads] do
      try do
        if :ets.whereis(tab) != :undefined, do: :ets.delete_all_objects(tab)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    for pid <- Process.get(:washy_thread_pids, []), is_pid(pid), do: Process.exit(pid, :kill)
    Process.delete(:washy_thread_pids)

    for {_id, %{transport: t}} when t != nil <- Map.values(Process.get(:washy_sockstate, %{})) do
      try do
        :gen_tcp.close(t)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    for key <- [:washy_sockstate, :washy_socknext, :washy_fdmap, :washy_descs, :washy_pipes, :washy_thread_id],
        do: Process.delete(key)

    :ok
  end

  # run `_start` under one interpreter lane, capturing {exit, stdout-bytes}.
  defp run(mod, cps?) do
    Process.delete(:washy_out)

    result =
      try do
        Washy.call_io(mod, "_start", [],
          transpile: false, cps: cps?, fuel: 1_000_000_000_000, max_depth: 1_000_000)

        :no_exit
      catch
        :throw, {:washy_exit, code} -> {:exit, code}
      end

    out = Process.get(:washy_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
    {result, out}
  end

  # the deterministic, non-networked fixtures — pure compute / fs / float / bignum / dynamic dispatch.
  # (socket/thread-pool fixtures add cross-process nondeterminism that isn't a fair bit-identical diff;
  # the compute-heavy set exercises every control-flow shape the trampoline reifies: deep recursion,
  # loops, br_table, call_indirect, nested blocks.)
  @fixtures ~w(rust_float rust_bignum rust_dynamic rust_compute rust_parse)

  # ── Stage 3: TRUE return-twice proc_fork on the reified-stack lane ──────────────────────────────
  # unix_fork.c: malloc a sentinel=100, fork(); child sets it 200 + _exit(7); parent waitpid asserts
  # status 7 AND that ITS copy is still 100 (memory isolation), then return 42. fork()→proc_fork is
  # intercepted in `tramp`; the child resumes the captured continuation over copied memory. This is
  # the proof that return-twice fork works without asyncify/native-stack capture (wb-nsrp).
  @tag timeout: 300_000
  test "unix_fork: true return-twice proc_fork — child isolated, parent reaps status 7, exits 42" do
    path = Path.join(@dir, "unix_fork.wasm")
    {:ok, mod} = Washy.decode(File.read!(path))
    mod = %{mod | id: :cps_fork_fixture}

    # the C path imports proc_fork (the split point) — no asyncify checkpoint needed here
    names = MapSet.new(mod.imports, fn {_m, name, _t} -> name end)
    assert "proc_fork" in names

    # AUTO-SELECT: a module importing proc_fork runs the reified-stack lane automatically (no cps: opt),
    # because the recursive interp can't capture the fork continuation. Returns 42 (return-twice works).
    Process.delete(:washy_out)

    auto =
      try do
        Washy.call_io(mod, "_start", [], transpile: false, fuel: 1_000_000_000_000, max_depth: 1_000_000)
        :no_exit
      catch
        :throw, {:washy_exit, code} -> {:exit, code}
      end

    assert auto == {:exit, 42},
           "fork must return-twice via auto-selected cps lane: child exits 7 in its own memory, parent sees its copy unchanged → 42"

    # explicit cps:true is identical
    assert run(mod, true) == {{:exit, 42}, ""}
  end

  for name <- @fixtures do
    test "#{name}: reified-stack interp ≡ recursive interp (exit + stdout)" do
      path = Path.join(@dir, unquote(name) <> ".wasm")

      if File.exists?(path) do
        {:ok, mod} = Washy.decode(File.read!(path))
        mod = %{mod | id: :"cps_oracle_#{unquote(name)}"}

        recursive = run(mod, false)
        trampoline = run(mod, true)

        assert recursive == trampoline,
               "#{unquote(name)}: recursive=#{inspect(recursive)} trampoline=#{inspect(trampoline)}"
      else
        IO.puts("skip #{unquote(name)} — fixture not present")
      end
    end
  end
end

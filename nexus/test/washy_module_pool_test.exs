defmodule Nexus.WashyModulePoolTest do
  @moduledoc """
  **The fixed recycled module-atom pool (atom-table wall, residual fix).** The JIT names generated BEAM
  modules with ATOMS, which never GC (~1,048,576 ceiling). `Nexus.Washy.ModulePool` pre-interns a FIXED
  pool of N module-name atoms and recycles slots, so total generated-module atoms are CONSTANT regardless
  of how many distinct programs run. These tests prove the three load-bearing properties:

    1. **Atom plateau** — compiling many MORE distinct chunks than the pool size does NOT grow the atom
       table past `pool size + a constant`.
    2. **Correctness under eviction** — a function whose module was recycled transparently recompiles into
       a fresh slot and runs BIT-IDENTICAL to the interpreter.
    3. **Never kill a guest** — a process executing an old version is NOT killed when its slot would be
       recycled (the soft_purge-skip path); the pool reports the slot busy and recycles a different one.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy
  alias Nexus.Washy.{Transpile, ModulePool}

  # A distinct single-function i32 module per `salt` — distinct `id` (own cache keys) AND distinct constant
  # (distinct generated code), so each compiles to its own pool slot. f(a) = (a + salt) & 0xFFFFFFFF.
  defp build(salt) do
    instrs = [{:local_get, 0}, {:i32_const, salt}, {:op, 0x6A}]

    %Washy{
      types: [{[127], [127]}],
      funcs: [0],
      code: [{0, instrs}],
      exports: %{"f" => 0},
      mem: {1, nil},
      globals: [],
      data: [],
      imports: [],
      elements: [],
      id: :crypto.hash(:sha256, :erlang.term_to_binary({:pool_test, salt}))
    }
  end

  # Force the function compiled to native via the lazy tier path (threshold 1, sync), returning the result.
  defp run_native(mod, args), do: Washy.call_io(mod, "f", args, transpile: true, tier_threshold: 1, tier_async: false)

  test "atom count PLATEAUS: churning far more distinct chunks than the pool size never grows atoms past N + const" do
    pool = 16
    ModulePool.reset(pool)

    # warm the machinery once so the first-time interning of helper atoms (wf_*, etc.) is already paid and
    # doesn't show up as growth in the measured window.
    run_native(build(0), [1])
    :erlang.garbage_collect()
    before = :erlang.system_info(:atom_count)

    # compile WAY more distinct programs than the pool holds (32×). If atoms grew per chunk this would add
    # ~512 atoms; with the pool it must stay within a small constant (a handful of wf_/transient atoms).
    churn = pool * 32

    for s <- 1..churn do
      m = build(s)
      {res, _io} = run_native(m, [10])
      assert res == rem(10 + s, 0x100000000)
    end

    after_count = :erlang.system_info(:atom_count)
    growth = after_count - before

    # the pool atoms (washy_pool_0..15) were all interned by reset BEFORE `before`, so they don't count
    # here; the only legitimate growth is a small constant of transient names. Assert it's nowhere near
    # the per-chunk count (which would be ~`churn`).
    assert growth < pool * 2,
           "atom table grew by #{growth} over #{churn} distinct chunks (pool=#{pool}) — expected a small constant, NOT O(chunks)"

    stats = ModulePool.stats()
    assert stats.size == pool
    assert stats.in_use <= pool, "in_use #{stats.in_use} must never exceed pool size #{pool}"
    assert stats.evictions > 0, "with #{churn} chunks through #{pool} slots, evictions must have happened"
  end

  test "correctness under eviction: an evicted function recompiles into a fresh slot, bit-identical to interp" do
    pool = 4
    ModulePool.reset(pool)

    victim = build(7)
    # compile it native and capture both lanes agree
    {interp, _} = Washy.call_io(victim, "f", [123], transpile: false)
    {native, _} = run_native(victim, [123])
    assert interp == native

    # the victim is now cached at some pool slot under some generation token.
    {:ok, {vmod, _vf, _va}} = Transpile.cached_one(victim.id, 0)
    vtok = ModulePool.token(vmod)

    # evict it: compile MANY other distinct programs, recycling the whole pool several times over so the
    # victim's slot is certainly recycled (its atom reused for other code OR purged) — its cached MFA dies.
    for s <- 100..(100 + pool * 8), do: run_native(build(s), [1])

    # PROVE an eviction really happened: the victim's slot generation advanced (atom reused) and/or the
    # module is no longer loaded — either way the cached MFA is no longer valid.
    refute ModulePool.valid?(vmod, vtok),
           "victim slot #{inspect(vmod)} (gen #{vtok}) should have been recycled — cached MFA must be invalid"

    # the cache lookup must now self-heal to a MISS (dangling entry dropped).
    assert Transpile.cached_one(victim.id, 0) == :miss,
           "lazy validation must report the evicted entry as :miss so dispatch recompiles"

    # now call the victim again via the JIT path: it must recompile into a FRESH slot and run bit-identical
    # to the interpreter (the whole point — never call dead/wrong code).
    {interp2, _} = Washy.call_io(victim, "f", [123], transpile: false)
    {native2, _} = run_native(victim, [123])
    assert interp2 == native2
    assert native2 == native, "recompiled-after-eviction result must equal the original (#{inspect(native)})"
  end

  # Load a trivial module under pool slot `slot`'s atom whose exported `block/1` parks in an infinite
  # receive — so a process calling it is genuinely SUSPENDED INSIDE that module's code (the exact condition
  # `check_process_code`/`soft_purge` detect as "executing this module"). This is how we simulate a guest
  # holding code mid-execution, without relying on the JIT-generated funcs (which never block).
  defp load_blocking_module(atom) do
    forms = [
      {:attribute, 1, :module, atom},
      {:attribute, 1, :export, [{:block, 1}]},
      {:function, 1, :block, 1,
       [
         {:clause, 1, [{:var, 1, :_Parent}], [],
          [
            # send a ready ping, then block forever inside this module's frame.
            {:call, 1, {:remote, 1, {:atom, 1, :erlang}, {:atom, 1, :send}}, [{:var, 1, :_Parent}, {:atom, 1, :in_module}]},
            {:receive, 1, [{:clause, 1, [{:atom, 1, :never}], [], [{:atom, 1, :ok}]}]}
          ]}
       ]}
    ]

    {:ok, ^atom, bin, _w} = :compile.forms(forms, [:return])
    {:module, ^atom} = :code.load_binary(atom, ~c"nofile", bin)
    :ok
  end

  test "NEVER kill a guest: a process executing an old version is not killed when its slot would be recycled" do
    # The pool slot atoms are `washy_pool_0..`. Take slot 0's atom and load a BLOCKING module under it,
    # then park a guest inside that module's code — the exact soft_purge-skip condition.
    ModulePool.reset(4)
    slot0 = String.to_existing_atom("washy_pool_0")
    load_blocking_module(slot0)

    test_pid = self()
    {parked, ref} = spawn_monitor(fn -> apply(slot0, :block, [test_pid]) end)
    assert_receive :in_module, 2_000

    # Make the current version OLD: now `parked` is SUSPENDED INSIDE the old code of slot0. A correct pool
    # must refuse to purge it (soft_purge returns false) and SKIP the slot — never hard-purge (which kills).
    :code.delete(slot0)
    assert :erlang.check_old_code(slot0)
    refute :code.soft_purge(slot0), "soft_purge must REFUSE while a process executes the old code"

    # Now exercise the pool: acquire repeatedly. It must SKIP slot0 (busy) and hand out other slots, and
    # must NEVER kill the parked guest.
    for _ <- 1..20 do
      assert {:ok, a, _tok} = ModulePool.acquire()
      refute a == slot0, "acquire must never hand out (and purge) the busy slot0 while the guest runs in it"
    end

    assert Process.alive?(parked), "the guest executing old code MUST NOT be killed by slot recycling"
    assert ModulePool.stats().skips > 0, "the busy slot must have been skipped, not purged"

    # Once the guest exits, the slot becomes purgeable again (soft_purge succeeds) — proving the skip was
    # temporary, not a permanent leak.
    Process.exit(parked, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^parked, _}, 2_000
    # give the scheduler a tick to drop the dead process's references
    Process.sleep(20)
    assert :code.soft_purge(slot0), "after the guest exits, the old code is finally purgeable"

    # restore a sane default pool for any later tests sharing the node.
    ModulePool.reset(256)
  end
end

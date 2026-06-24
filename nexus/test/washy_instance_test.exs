defmodule Nexus.WashyInstanceTest do
  @moduledoc """
  Persistent-instance mechanism (wb: JS guest-actor state across messages). Proves that a guest's wasm
  instance — its linear memory + globals + runtime context — STAYS ALIVE between `instance_invoke` calls,
  so state mutated by one export call is visible to the next. This is the host-side foundation under the
  JS actor: re-enter `wb_dispatch` per message with the QuickJS heap intact (see JS-PERSISTENCE-DESIGN.md).

  We can't rebuild qjs-run.wasm here, so we exercise the MECHANISM with a hand-built counter module:
  a memory at addr 0 holds an i32 counter; `inc()` loads/+1/stores and returns the new value; `get()`
  returns the current value. If memory persisted across invocations, three `inc`s yield 1, 2, 3.

  Also covers a GLOBAL-backed counter (mutable global persists too) and explicit `instance_free`.
  """
  use ExUnit.Case, async: true

  alias Nexus.Washy
  alias Nexus.Washy.Instance

  # inc(): mem[0] = mem[0] + 1; return mem[0]   — memory-backed counter at address 0
  #   i32.const 0          ; store address
  #   i32.const 0          ; load address
  #   i32.load             ;   -> old
  #   i32.const 1
  #   i32.add              ;   -> new      (stack: addr, new)
  #   i32.store            ; mem[0] = new
  #   i32.const 0
  #   i32.load             ; return mem[0]
  @inc_instrs [
    {:i32_const, 0},
    {:i32_const, 0},
    {:i32_load, 0},
    {:i32_const, 1},
    {:op, 0x6A},
    {:i32_store, 0},
    {:i32_const, 0},
    {:i32_load, 0}
  ]

  # get(): return mem[0]
  @get_instrs [{:i32_const, 0}, {:i32_load, 0}]

  # _start(): no-op setup (the persistence happens in memory, which new_mem zero-inits)
  @start_instrs []

  defp counter_mod do
    %Washy{
      types: [{[], [127]}, {[], []}],
      # three local funcs: 0=_start (type 1, void), 1=inc (type 0), 2=get (type 0)
      funcs: [1, 0, 0],
      code: [{0, @start_instrs}, {0, @inc_instrs}, {0, @get_instrs}],
      exports: %{"_start" => 0, "inc" => 1, "get" => 2},
      mem: {1, nil},
      globals: [],
      data: [],
      imports: [],
      elements: [],
      id: :crypto.hash(:sha256, "washy-instance-counter-test")
    }
  end

  test "memory persists across invocations on the SAME instance: inc x3 == 3" do
    {:ok, inst, ""} = Washy.instance_start(counter_mod(), "_start")
    assert %Instance{} = inst

    {:ok, 1, "", inst} = Washy.instance_invoke(inst, "inc")
    {:ok, 2, "", inst} = Washy.instance_invoke(inst, "inc")
    {:ok, 3, "", inst} = Washy.instance_invoke(inst, "inc")

    # get() reads the same persisted memory
    {:ok, 3, "", _inst} = Washy.instance_invoke(inst, "get")
  end

  test "a fresh instance starts from zero (state is per-instance, not global)" do
    {:ok, a, ""} = Washy.instance_start(counter_mod(), "_start")
    {:ok, 1, "", a} = Washy.instance_invoke(a, "inc")
    {:ok, 2, "", _a} = Washy.instance_invoke(a, "inc")

    {:ok, b, ""} = Washy.instance_start(counter_mod(), "_start")
    # b's memory is independent — its first inc is 1, unaffected by a's two incs
    {:ok, 1, "", _b} = Washy.instance_invoke(b, "inc")
  end

  # a mutable-global-backed counter — proves globals persist across invokes too, not just memory.
  defp global_counter_mod do
    %Washy{
      types: [{[], [127]}, {[], []}],
      funcs: [1, 0],
      code: [
        {0, []},
        # global0 = global0 + 1; return global0
        {0, [{:global_get, 0}, {:i32_const, 1}, {:op, 0x6A}, {:global_set, 0}, {:global_get, 0}]}
      ],
      exports: %{"_start" => 0, "bump" => 1},
      mem: {1, nil},
      # one mutable i32 global, init 0  (init expr: i32.const 0)
      globals: [[{:i32_const, 0}]],
      data: [],
      imports: [],
      elements: [],
      id: :crypto.hash(:sha256, "washy-instance-global-counter")
    }
  end

  test "mutable globals persist across invocations on the SAME instance" do
    {:ok, inst, ""} = Washy.instance_start(global_counter_mod(), "_start")
    {:ok, 1, "", inst} = Washy.instance_invoke(inst, "bump")
    {:ok, 2, "", inst} = Washy.instance_invoke(inst, "bump")
    {:ok, 3, "", _inst} = Washy.instance_invoke(inst, "bump")
  end

  test "instance_free returns :ok and the instance is a plain struct (no native resource)" do
    {:ok, inst, ""} = Washy.instance_start(counter_mod(), "_start")
    assert :ok = Washy.instance_free(inst)
    # freeing is advisory; the held atomics are GC-reclaimed once the handle is dropped.
  end

  test "instance ops do not clobber the caller's outer run context (nesting-safe)" do
    # simulate an outer run holding context
    Process.put(:washy_rt, :outer_marker)
    Process.put(:washy_mem, :outer_mem)

    {:ok, inst, ""} = Washy.instance_start(counter_mod(), "_start")
    {:ok, 1, "", _inst} = Washy.instance_invoke(inst, "inc")

    assert Process.get(:washy_rt) == :outer_marker
    assert Process.get(:washy_mem) == :outer_mem
  after
    Process.delete(:washy_rt)
    Process.delete(:washy_mem)
  end
end

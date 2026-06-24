defmodule Nexus.WashyAsmTest do
  @moduledoc """
  **BEAM-assembly emission lane (epic wb-wzdq / wb-9icg).** `TranspileAsm.try_emit/2` lowers a wasm
  function straight to BEAM assembly and compiles it via `:compile.forms(.., [:from_asm])` — skipping the
  Erlang frontend + the superlinear `beam_ssa_opt` by construction, BeamAsm JITs to native. The contract
  is the same as the abstract-forms lane: **bit-identical to the interpreter**. This A/Bs the SAME
  functions through interp, the forms-native lane, and the asm-native lane — all three must agree — and
  asserts unsupported shapes fall back cleanly.
  """
  use ExUnit.Case, async: true

  alias Nexus.Washy
  alias Nexus.Washy.{Transpile, TranspileAsm}

  defp build(nlocals, instrs) do
    %Washy{
      types: [{[127, 127], [127]}],
      funcs: [0],
      code: [{nlocals, instrs}],
      exports: %{"f" => 0},
      mem: {1, nil},
      globals: [],
      data: [],
      imports: [],
      elements: [],
      id: :crypto.hash(:sha256, :erlang.term_to_binary({nlocals, instrs}))
    }
  end

  @argsets [[0, 0], [5, 3], [3, 1], [0xFFFFFFFF, 2], [100, 7], [0xFFFFFFFF, 0xFFFFFFFF]]

  @cases [
    {"a+b", 0, [{:local_get, 0}, {:local_get, 1}, {:op, 0x6A}]},
    {"a*b-a", 0, [{:local_get, 0}, {:local_get, 1}, {:op, 0x6C}, {:local_get, 0}, {:op, 0x6B}]},
    {"a+7", 0, [{:local_get, 0}, {:i32_const, 7}, {:op, 0x6A}]},
    {"(a&b)|(a^b)", 0,
     [{:local_get, 0}, {:local_get, 1}, {:op, 0x71}, {:local_get, 0}, {:local_get, 1}, {:op, 0x73}, {:op, 0x72}]},
    {"c=a+b;c*c", 1,
     [{:local_get, 0}, {:local_get, 1}, {:op, 0x6A}, {:local_set, 2}, {:local_get, 2}, {:local_get, 2}, {:op, 0x6C}]},
    {"tee: a+(a:=a*b)", 1,
     [{:local_get, 0}, {:local_get, 0}, {:local_get, 1}, {:op, 0x6C}, {:local_tee, 2}, {:op, 0x6A}]}
  ]

  test "asm-native == forms-native == interpreter, bit-identical, across the supported i32 subset" do
    for {name, nlocals, instrs} <- @cases do
      m = build(nlocals, instrs)
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "#{name}: should emit via from_asm"

      for args <- @argsets do
        {interp, _} = Washy.call_io(m, "f", args, transpile: false)
        {forms, _} = Washy.call_io(m, "f", args, transpile: true, tier_threshold: 1, tier_async: false)
        asm = apply(am, af, args)
        assert interp == forms and forms == asm,
               "#{name} @ #{inspect(args)}: interp=#{inspect(interp)} forms=#{inspect(forms)} asm=#{inspect(asm)}"
      end
    end
  end

  @cmp_args [[5, 3], [3, 5], [5, 5], [0, 0], [0xFFFFFFFF, 1], [1, 0xFFFFFFFF], [0x80000000, 1], [0x7FFFFFFF, 0x80000000]]
  @cmps [
    {"eq", 0x46}, {"ne", 0x47}, {"lt_s", 0x48}, {"lt_u", 0x49}, {"gt_s", 0x4A},
    {"gt_u", 0x4B}, {"le_s", 0x4C}, {"le_u", 0x4D}, {"ge_s", 0x4E}, {"ge_u", 0x4F}
  ]

  test "value-producing comparisons (signed+unsigned) == interp == forms, incl. sign boundaries" do
    for {name, op} <- @cmps do
      m = build(0, [{:local_get, 0}, {:local_get, 1}, {:op, op}])
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "#{name} should emit"

      for args <- @cmp_args do
        {interp, _} = Washy.call_io(m, "f", args, transpile: false)
        {forms, _} = Washy.call_io(m, "f", args, transpile: true, tier_threshold: 1, tier_async: false)
        asm = apply(am, af, args)
        assert interp == forms and forms == asm,
               "#{name} @ #{inspect(args)}: interp=#{inspect(interp)} forms=#{inspect(forms)} asm=#{inspect(asm)}"
      end
    end
  end

  test "eqz == interp" do
    m = build(0, [{:local_get, 0}, {:op, 0x45}])
    {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0)
    for args <- [[0, 0], [1, 0], [0xFFFFFFFF, 0]] do
      {interp, _} = Washy.call_io(m, "f", args, transpile: false)
      assert interp == apply(am, af, args)
    end
  end

  @cf_cases [
    {"loop: sum 1..n", 1,
     [
       {:i32_const, 0}, {:local_set, 2},
       {:loop,
        [
          {:local_get, 2}, {:local_get, 0}, {:op, 0x6A}, {:local_set, 2},
          {:local_get, 0}, {:i32_const, 1}, {:op, 0x6B}, {:local_tee, 0}, {:br_if, 0}
        ]},
       {:local_get, 2}
     ], [[5, 0], [10, 0], [1, 0], [100, 0]]},
    {"if/else: c = a ? b : 99", 1,
     [
       {:local_get, 0},
       {:if, [{:local_get, 1}, {:local_set, 2}], [{:i32_const, 99}, {:local_set, 2}]},
       {:local_get, 2}
     ], [[0, 7], [1, 7], [5, 3]]},
    {"block + br (early exit)", 1,
     [
       {:i32_const, 42}, {:local_set, 2},
       {:block, [{:local_get, 0}, {:br_if, 0}, {:i32_const, 7}, {:local_set, 2}]},
       {:local_get, 2}
     ], [[0, 0], [1, 0], [9, 0]]}
  ]

  test "structured control flow (loop/if/block + br/br_if) == interp == forms, bit-identical" do
    for {name, nlocals, instrs, argsets} <- @cf_cases do
      m = build(nlocals, instrs)
      assert {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0), "#{name} should emit via from_asm"

      for args <- argsets do
        {interp, _} = Washy.call_io(m, "f", args, fuel: 50_000_000, transpile: false)
        {forms, _} = Washy.call_io(m, "f", args, fuel: 50_000_000, transpile: true, tier_threshold: 1, tier_async: false)
        asm = apply(am, af, args)
        assert interp == forms and forms == asm,
               "#{name} @ #{inspect(args)}: interp=#{inspect(interp)} forms=#{inspect(forms)} asm=#{inspect(asm)}"
      end
    end
  end

  test "an asm-native loop runs far faster than the interpreter (the runtime payoff)" do
    instrs = [
      {:i32_const, 0}, {:local_set, 2},
      {:loop,
       [
         {:local_get, 2}, {:local_get, 0}, {:op, 0x6A}, {:local_set, 2},
         {:local_get, 0}, {:i32_const, 1}, {:op, 0x6B}, {:local_tee, 0}, {:br_if, 0}
       ]},
      {:local_get, 2}
    ]
    m = build(1, instrs)
    {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0)
    n = 1_000_000
    {t_interp, _} = :timer.tc(fn -> Washy.call_io(m, "f", [n, 0], fuel: 100_000_000_000, transpile: false) end)
    {t_asm, asm} = :timer.tc(fn -> apply(am, af, [n, 0]) end)
    {interp, _} = Washy.call_io(m, "f", [n, 0], fuel: 100_000_000_000, transpile: false)
    assert interp == asm
    assert t_asm * 5 < t_interp, "asm should be much faster: interp=#{div(t_interp, 1000)}ms asm=#{div(t_asm, 1000)}ms"
  end

  test "the asm lane wraps i32 arithmetic mod 2^32 exactly like the interpreter" do
    m = build(0, [{:local_get, 0}, {:local_get, 1}, {:op, 0x6A}])
    {:ok, {am, af, _}} = TranspileAsm.try_emit(m, 0)
    # 0xFFFFFFFF + 2 wraps to 1
    assert apply(am, af, [0xFFFFFFFF, 2]) == 1
    {interp, _} = Washy.call_io(m, "f", [0xFFFFFFFF, 2], transpile: false)
    assert interp == 1
  end

  test "out-of-subset shapes return :unsupported (clean fallback, never wrong code)" do
    # a call → not a leaf; a block → control flow; memory.size → memory; i64 → wrong type. All deferred.
    assert :unsupported = TranspileAsm.try_emit(build(0, [{:local_get, 0}, {:call, 0}]), 0)
    assert :unsupported = TranspileAsm.try_emit(build(0, [{:block, [{:local_get, 0}]}]), 0)
    assert :unsupported = TranspileAsm.try_emit(build(0, [{:memory_size}, {:drop}, {:local_get, 0}]), 0)
    # a shift (0x74 i32.shl) is not in this increment yet
    assert :unsupported = TranspileAsm.try_emit(build(0, [{:local_get, 0}, {:local_get, 1}, {:op, 0x74}]), 0)
  end

  test "from_asm compiles dramatically faster than abstract forms (the whole point)" do
    big = [{:local_get, 0} | Enum.flat_map(1..400, fn k -> [{:i32_const, k}, {:op, 0x6A}] end)]
    m = build(0, big)
    {t_asm, {:ok, _}} = :timer.tc(fn -> TranspileAsm.try_emit(m, 0) end)
    {t_forms, _} = :timer.tc(fn -> Transpile.compile_one(m, 0) end)
    # asm skips the SSA pipeline entirely; expect a large margin (measured ~20x). Assert a safe floor.
    assert t_asm * 3 < t_forms, "asm=#{div(t_asm, 1000)}ms forms=#{div(t_forms, 1000)}ms — expected asm much faster"
  end
end

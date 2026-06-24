defmodule Nexus.Washy.TranspileAsm do
  @moduledoc """
  **The BEAM-assembly emission lane (epic wb-wzdq).** Lowers a wasm function straight to BEAM *assembly*
  (`{function,...}` opcode tuples) and compiles it with `:compile.forms(asm, [:from_asm])` — skipping the
  Erlang frontend AND the superlinear `beam_ssa_opt` pass *by construction*, then letting BeamAsm JIT the
  result to native. wasm opcodes ↔ BEAM asm opcodes is a near-1:1 transliteration; the compile is ~linear.
  See `nexus/reference/beam/` for the ground-truth instruction set + the validated API.

  **Register model — FRAME-based (the call-safe model).** A function gets a stack frame (`allocate`/
  `deallocate`); ALL persistent values live in `y`-registers (which survive calls): locals in `y0..y(L-1)`
  (params moved in from `x0..`; declared locals zero-init'd), and the wasm operand stack of depth `d` in
  `y(L)..y(L+d-1)`. `x0`/`x1` are transient scratch — values are loaded from `y`, the op runs, the result
  is stored back to `y`. This is what makes calls/fuel/memory work: a `call` clobbers `x` but the frame
  (`y`) is preserved, so no spilling dance is needed.

  **Supported ops:** i32 const, `local.get/set/tee`, `drop`, `nop`; i32 arith/bitwise (add/sub/mul/and/
  or/xor); all i32 compares (signed via branchless s32) + `eqz`; structured VOID control flow (block/loop/
  if + br/br_if via real labels/jumps) with **fuel charged per loop iteration** (traps `:out_of_fuel` like
  the interpreter). Out-of-scope (calls/memory/i64/floats/value-producing blocks/early-return) → returns
  `:unsupported`, caller falls back to the abstract-forms lane. The contract: bit-identical to interp.
  """
  import Bitwise
  import Nexus.Washy.AsmCtx

  @mask32 0xFFFFFFFF
  @washy :"Elixir.Nexus.Washy"

  # Pluggable op-group handlers (the parallel-built AsmOps.* modules). Each exposes `handle(instr, s) ->
  # {:ok, s} | :unsupported`. step/2 tries them in order for any op the built-in i32 core doesn't cover.
  @op_handlers [Nexus.Washy.AsmOps.Memory, Nexus.Washy.AsmOps.I64, Nexus.Washy.AsmOps.Floats]

  # wasm i32 opcode → {beam_gc_bif, needs_32bit_mask?}. add/sub/mul wrap mod 2^32 (mask); and/or/xor stay
  # in range. band of a negative (sub underflow) two's-complements to the correct unsigned wrap.
  @binops %{
    0x6A => {:+, true},
    0x6B => {:-, true},
    0x6C => {:*, true},
    0x71 => {:band, false},
    0x72 => {:bor, false},
    0x73 => {:bxor, false}
  }

  # wasm i32 comparison opcode → {operand-domain, beam-test, swap-args?}. `:u` compares unsigned stored
  # values directly; `:s` converts both to signed-32 first (branchless); `:eq`/`:ne` exact equality.
  @compares %{
    0x46 => {:eq, :is_eq_exact, false},
    0x47 => {:ne, :is_ne_exact, false},
    0x48 => {:s, :is_lt, false},
    0x49 => {:u, :is_lt, false},
    0x4A => {:s, :is_lt, true},
    0x4B => {:u, :is_lt, true},
    0x4C => {:s, :is_ge, true},
    0x4D => {:u, :is_ge, true},
    0x4E => {:s, :is_ge, false},
    0x4F => {:u, :is_ge, false}
  }

  @doc """
  Try to compile global-function-index `gfidx` via the BEAM-assembly lane. Returns `{:ok, {mod, fun,
  arity}}` (a loaded native MFA), `:unsupported` (op/shape outside scope — fall back), or `:error`.
  """
  def try_emit(mod, gfidx) do
    ni = length(mod.imports)
    li = gfidx - ni
    {nlocals, instrs} = Enum.at(mod.code, li)
    {params, results} = Enum.at(mod.types, Enum.at(mod.funcs, li))
    arity = length(params)

    if supported_sig?(params, results) do
      l = arity + nlocals
      {body, num_labels} = emit_body(instrs, l, arity, nlocals, mod, ni)
      assemble(gfidx, arity, body, num_labels)
    else
      :unsupported
    end
  catch
    :unsupported -> :unsupported
  end

  defp supported_sig?(params, [127]), do: Enum.all?(params, &(&1 == 127))
  defp supported_sig?(_, _), do: false

  # State `s`: acc (reverse-chronological instrs), d (operand depth), maxd (max depth, sizes the frame),
  # lbl (next free label), reachable, ctrl (control-frame stack), used (labels some br targets), l (#locals).
  defp emit_body(instrs, l, arity, _nlocals, mod, ni) do
    s0 = %{acc: [], d: 0, maxd: 0, lbl: 3, reachable: true, ctrl: [], used: MapSet.new(), l: l, mod: mod, ni: ni}
    s = lower_seq(instrs, s0)

    unless s.reachable and s.d == 1, do: throw(:unsupported)
    frame = l + max(s.maxd, 1)
    # Prologue: allocate the frame, move params x→y, then zero-init EVERY remaining y-slot (declared
    # locals + operand-stack scratch). A call (charge_fuel/call_local) may GC and scans the whole frame,
    # so all y-slots must be initialized before the first call — even scratch slots written later.
    param_moves = for i <- 0..(arity - 1)//1, arity > 0, do: {:move, {:x, i}, {:y, i}}
    zero = for i <- arity..(frame - 1)//1, i >= arity, do: {:move, {:integer, 0}, {:y, i}}
    prologue = [{:allocate, frame, arity}] ++ param_moves ++ zero
    tail = [{:move, {:y, l}, {:x, 0}}, {:deallocate, frame}, :return]
    body = prologue ++ Enum.reverse(s.acc) ++ tail
    {patch_dealloc(body, frame), s.lbl}
  end

  defp patch_dealloc(body, frame), do: Enum.map(body, fn {:deallocate, :ph} -> {:deallocate, frame}; i -> i end)

  defp lower_seq(instrs, s), do: Enum.reduce(instrs, s, &step/2)

  # ── dead code: skip until a join label restores reachability ──
  defp step(_instr, %{reachable: false} = s), do: s

  # ── structured control flow (VOID constructs only) ──
  defp step({:block, body}, s) do
    {lend, s} = new_label(s)
    frame = %{label: lend, entry: s.d, loop?: false}
    s1 = lower_seq(body, %{s | ctrl: [frame | s.ctrl]})
    if s1.reachable and s1.d != frame.entry, do: throw(:unsupported)
    reach = s1.reachable or MapSet.member?(s1.used, lend)
    emit(%{s1 | ctrl: tl(s1.ctrl), d: frame.entry, reachable: reach}, [{:label, lend}])
  end

  defp step({:loop, body}, s) do
    {lstart, s} = new_label(s)
    # charge fuel on each iteration (entry) so a transpiled loop traps :out_of_fuel like the interpreter
    # instead of spinning unbounded. charge_fuel/0 throws on exhaustion; the throw unwinds the frame.
    s = emit(s, [{:label, lstart}, {:call_ext, 0, {:extfunc, @washy, :charge_fuel, 0}}])
    frame = %{label: lstart, entry: s.d, loop?: true}
    s1 = lower_seq(body, %{s | ctrl: [frame | s.ctrl]})
    if s1.reachable and s1.d != frame.entry, do: throw(:unsupported)
    %{s1 | ctrl: tl(s1.ctrl), d: frame.entry}
  end

  defp step({:if, then_b, else_b}, s) do
    if s.d < 1, do: throw(:unsupported)
    d1 = s.d - 1
    {lelse, s} = new_label(s)
    {lend, s} = new_label(s)
    s = emit(s, [{:move, yd(s, s.d - 1), {:x, 0}}, {:test, :is_ne_exact, {:f, lelse}, [{:x, 0}, {:integer, 0}]}])
    frame = %{label: lend, entry: d1, loop?: false}
    st = lower_seq(then_b, %{s | d: d1, reachable: true, ctrl: [frame | s.ctrl]})
    if st.reachable and st.d != d1, do: throw(:unsupported)
    then_reach = st.reachable
    st = if then_reach, do: emit(st, [{:jump, {:f, lend}}]), else: st
    st = emit(st, [{:label, lelse}])
    se = lower_seq(else_b, %{st | d: d1, reachable: true})
    if se.reachable and se.d != d1, do: throw(:unsupported)
    reach = then_reach or se.reachable or MapSet.member?(se.used, lend)
    emit(%{se | ctrl: tl(se.ctrl), d: d1, reachable: reach}, [{:label, lend}])
  end

  defp step({:br, n}, s) do
    frame = Enum.at(s.ctrl, n) || throw(:unsupported)
    if frame.entry != s.d, do: throw(:unsupported)
    s = emit(s, [{:jump, {:f, frame.label}}])
    %{s | reachable: false, used: MapSet.put(s.used, frame.label)}
  end

  defp step({:br_if, n}, s) do
    if s.d < 1, do: throw(:unsupported)
    d1 = s.d - 1
    frame = Enum.at(s.ctrl, n) || throw(:unsupported)
    if frame.entry != d1, do: throw(:unsupported)
    # branch to target iff cond != 0; is_eq_exact falls through (continue) when cond == 0.
    s = emit(s, [{:move, yd(s, s.d - 1), {:x, 0}}, {:test, :is_eq_exact, {:f, frame.label}, [{:x, 0}, {:integer, 0}]}])
    %{s | d: d1, used: MapSet.put(s.used, frame.label)}
  end

  defp step({:return}, s) do
    if s.d < 1, do: throw(:unsupported)
    s = emit(s, [{:move, yd(s, s.d - 1), {:x, 0}}, {:deallocate, :ph}, :return])
    %{s | reachable: false}
  end

  # ── values / locals ──
  defp step({:i32_const, v}, s), do: push(emit(s, [{:move, {:integer, v &&& @mask32}, yd(s, s.d)}]))

  defp step({:local_get, i}, s), do: push(emit(s, [{:move, {:y, i}, {:x, 0}}, {:move, {:x, 0}, yd(s, s.d)}]))

  defp step({:local_set, i}, s) do
    if s.d < 1, do: throw(:unsupported)
    %{emit(s, [{:move, yd(s, s.d - 1), {:x, 0}}, {:move, {:x, 0}, {:y, i}}]) | d: s.d - 1}
  end

  defp step({:local_tee, i}, s) do
    if s.d < 1, do: throw(:unsupported)
    emit(s, [{:move, yd(s, s.d - 1), {:x, 0}}, {:move, {:x, 0}, {:y, i}}])
  end

  defp step({:drop}, s) do
    if s.d < 1, do: throw(:unsupported)
    %{s | d: s.d - 1}
  end

  defp step({:nop}, s), do: s

  defp step({:op, opcode} = instr, s) do
    cond do
      Map.has_key?(@binops, opcode) -> binop(opcode, s)
      Map.has_key?(@compares, opcode) -> compare(opcode, s)
      opcode == 0x45 -> eqz(s)
      true -> try_handlers(instr, s)
    end
  end

  # ── calls (direct). The frame (y) survives the call, so no spilling: build the args list from the top
  # y-slots, set the callee selector in x0, call_ext the trampoline. A LOCAL fn → call_local/2 (runs it on
  # the shared interp/native state); a host IMPORT → invoke_host/2 (same seam the interpreter uses). ──
  defp step({:call, fidx}, s) when fidx >= 0 do
    {params, results} = func_type(s.mod, s.ni, fidx)
    np = length(params)
    nr = length(results)
    # i32-only args/result for now (i64/f64 calls deferred); single result max.
    unless Enum.all?(params, &(&1 == 127)) and Enum.all?(results, &(&1 == 127)) and nr <= 1, do: throw(:unsupported)
    if s.d < np, do: throw(:unsupported)

    build = build_arglist(s, np)

    selector =
      if fidx < s.ni do
        [{:move, {:literal, Enum.at(s.mod.imports, fidx)}, {:x, 0}}, {:call_ext, 2, {:extfunc, @washy, :invoke_host, 2}}]
      else
        [{:move, {:integer, fidx}, {:x, 0}}, {:call_ext, 2, {:extfunc, @washy, :call_local, 2}}]
      end

    s1 = %{s | d: s.d - np}

    if nr == 1,
      do: push(emit(s1, build ++ selector ++ [{:move, {:x, 0}, yd(s1, s1.d)}])),
      else: emit(s1, build ++ selector)
  end

  defp step(instr, s), do: try_handlers(instr, s)

  # try each pluggable op-group handler; first that accepts wins, else the function falls back to forms.
  defp try_handlers(instr, s) do
    Enum.reduce_while(@op_handlers, :unsupported, fn mod, _ ->
      case mod.handle(instr, s) do
        {:ok, s2} -> {:halt, s2}
        :unsupported -> {:cont, :unsupported}
      end
    end)
    |> case do
      :unsupported -> throw(:unsupported)
      s2 -> s2
    end
  end

  # build the Erlang arg list [arg0, …, arg(np-1)] (in call order) into x1 from the top np operand slots.
  defp build_arglist(_s, 0), do: [{:move, nil, {:x, 1}}]

  defp build_arglist(s, np) do
    puts =
      for p <- (np - 1)..0//-1 do
        tail = if p == np - 1, do: nil, else: {:x, 1}
        [{:move, yd(s, s.d - np + p), {:x, 0}}, {:put_list, {:x, 0}, tail, {:x, 1}}]
      end

    [{:test_heap, 2 * np, 0} | List.flatten(puts)]
  end

  defp binop(opcode, s) do
    if s.d < 2, do: throw(:unsupported)
    {beam_op, mask?} = @binops[opcode]

    ops =
      [{:move, yd(s, s.d - 2), {:x, 0}}, {:move, yd(s, s.d - 1), {:x, 1}},
       {:gc_bif, beam_op, {:f, 0}, 2, [{:x, 0}, {:x, 1}], {:x, 0}}] ++
        if(mask?, do: [{:gc_bif, :band, {:f, 0}, 1, [{:x, 0}, {:integer, @mask32}], {:x, 0}}], else: []) ++
        [{:move, {:x, 0}, yd(s, s.d - 2)}]

    %{emit(s, ops) | d: s.d - 1}
  end

  defp compare(opcode, s) do
    if s.d < 2, do: throw(:unsupported)
    {domain, test_op, swap?} = @compares[opcode]
    load = [{:move, yd(s, s.d - 2), {:x, 0}}, {:move, yd(s, s.d - 1), {:x, 1}}]
    sconv = if domain == :s, do: signed_ops({:x, 0}, 32) ++ signed_ops({:x, 1}, 32), else: []
    args = if swap?, do: [{:x, 1}, {:x, 0}], else: [{:x, 0}, {:x, 1}]
    store = [{:move, {:x, 0}, yd(s, s.d - 2)}]
    %{emit(s, load ++ sconv ++ branch01(test_op, args, {:x, 0}, s) ++ store) | d: s.d - 1} |> bump_labels(2)
  end

  defp eqz(s) do
    if s.d < 1, do: throw(:unsupported)
    load = [{:move, yd(s, s.d - 1), {:x, 0}}]
    store = [{:move, {:x, 0}, yd(s, s.d - 1)}]
    bump_labels(emit(s, load ++ branch01(:is_eq_exact, [{:x, 0}, {:integer, 0}], {:x, 0}, s) ++ store), 2)
  end

  # build the from_asm 5-tuple, compile in-memory, load native.
  defp assemble(gfidx, arity, body, num_labels) do
    mname = :"washy_asm_#{System.unique_integer([:positive])}"
    fname = :"wf_#{gfidx}"

    code = [
      {:function, fname, arity, 2, [{:label, 1}, {:func_info, {:atom, mname}, {:atom, fname}, arity}, {:label, 2} | body]}
    ]

    asm = {mname, [{fname, arity}], [], code, num_labels}

    case :compile.forms(asm, [:from_asm, :binary, :return_errors]) do
      {:ok, ^mname, bin} ->
        {:module, ^mname} = :code.load_binary(mname, ~c"nofile", bin)
        {:ok, {mname, fname, arity}}

      {:ok, ^mname, bin, _warns} ->
        {:module, ^mname} = :code.load_binary(mname, ~c"nofile", bin)
        {:ok, {mname, fname, arity}}

      other ->
        if System.get_env("WB_ASM_DEBUG"), do: IO.inspect({other, asm}, label: "asm-fail", limit: :infinity)
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end

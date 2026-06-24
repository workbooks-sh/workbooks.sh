defmodule Nexus.Washy.TranspileAsm do
  @moduledoc """
  **The BEAM-assembly emission lane (epic wb-wzdq / wb-9icg).** Lowers a wasm function straight to BEAM
  *assembly* (`{function,...}` opcode tuples) and compiles it with `:compile.forms(asm, [:from_asm])` —
  skipping the Erlang frontend AND the superlinear `beam_ssa_opt` pass *by construction*, then letting
  BeamAsm JIT the result to native. This is the low-rung target: wasm opcodes ↔ BEAM asm opcodes is a
  near-1:1 transliteration, the compile is ~linear, and we get native speed without a NIF or a wasmtime
  subprocess. See `nexus/reference/beam/` for the ground-truth instruction set + the validated API.

  **Scope of THIS increment (wb-9icg):** straight-line **leaf** `i32 -> i32` functions — `i32.const`,
  `local.get/set/tee`, `drop`, `nop`, and the non-branching i32 arithmetic/bitwise binops
  (`add/sub/mul/and/or/xor`). Anything else (control flow, calls, memory, compares/shifts needing
  branches, i64/floats) returns `:unsupported` and the caller falls back to the abstract-forms lane.
  Control flow + the full op set are wb-tdtz. The contract is identical to the forms lane: a native run
  is **bit-identical** to the interpreter (oracle/fuzzer gated).

  Register/stack model (leaf ⇒ free use of x-registers): locals live in `x0..x(L-1)` (params arrive
  there; declared locals zero-init'd); the wasm operand stack of depth `d` lives in `x(L)..x(L+d-1)`.
  Each push writes the next slot; each binop reads two slots and writes the lower one. Result → `x0`.
  """
  import Bitwise

  @mask32 0xFFFFFFFF
  @sign 0x80000000

  # wasm i32 opcode → {beam_gc_bif, needs_32bit_mask?}. Only the non-branching, no-sign-conversion ops:
  # add/sub/mul wrap mod 2^32 (mask); and/or/xor stay in range (no mask). band of a negative (sub
  # underflow) two's-complements to the correct unsigned wrap, matching the interpreter.
  @binops %{
    0x6A => {:+, true},
    0x6B => {:-, true},
    0x6C => {:*, true},
    0x71 => {:band, false},
    0x72 => {:bor, false},
    0x73 => {:bxor, false}
  }

  # wasm i32 comparison opcode → {operand-domain, beam-test, swap-args?}. The result is a 0/1 value,
  # materialized with a test+branch. `:u` = compare the unsigned stored values directly; `:s` = convert
  # BOTH operands to signed-32 first (branchless, see s32_ops/2); `:eq`/`:ne` = exact equality.
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
  arity}}` (a loaded native MFA, same shape as `Transpile.compile_one/2`), `:unsupported` (op/shape
  outside this increment — fall back), or `:error` (assembled but rejected/failed).
  """
  def try_emit(mod, gfidx) do
    ni = length(mod.imports)
    li = gfidx - ni
    {nlocals, instrs} = Enum.at(mod.code, li)
    {params, results} = Enum.at(mod.types, Enum.at(mod.funcs, li))
    arity = length(params)

    if supported_sig?(params, results) do
      l = arity + nlocals
      {body, num_labels} = emit_body(instrs, l, arity, nlocals)
      assemble(gfidx, arity, body, num_labels)
    else
      :unsupported
    end
  catch
    :unsupported -> :unsupported
  end

  # only (i32, …) -> (i32): every param and the single result is i32 (wasm valtype 0x7F = 127).
  defp supported_sig?(params, [127]), do: Enum.all?(params, &(&1 == 127))
  defp supported_sig?(_, _), do: false

  # fold the wasm body into BEAM-asm instructions. State `s` = %{acc: reverse-chronological instrs,
  # d: operand-stack depth, lbl: next free label}. reg(d) = {x, L+d}. Function labels 1,2 are the
  # entry; body labels start at 3.
  # State `s`: acc (reverse-chronological instrs), d (operand depth), lbl (next free label), reachable
  # (false in dead code after br/return), ctrl (control-frame stack; head = innermost), used (set of
  # labels that some br targets — tells us whether a join label is reachable).
  defp emit_body(instrs, l, arity, nlocals) do
    zero = for i <- arity..(l - 1)//1, i >= arity, do: {:move, {:integer, 0}, {:x, i}}
    s0 = %{acc: Enum.reverse(zero), d: 0, lbl: 3, reachable: true, ctrl: [], used: MapSet.new()}

    s = lower_seq(instrs, s0, l)

    # function must end reachable producing exactly one i32 (top-level early-return/value-blocks → fallback)
    unless s.reachable and s.d == 1, do: throw(:unsupported)
    tail = if l == 0, do: [:return], else: [{:move, {:x, l}, {:x, 0}}, :return]
    {Enum.reverse(s.acc) ++ tail, s.lbl}
  end

  defp lower_seq(instrs, s, l), do: Enum.reduce(instrs, s, fn instr, s -> step(instr, s, l) end)

  # emit one or more instructions (chronological) into the reverse-chronological acc.
  defp emit(s, ops), do: %{s | acc: Enum.reverse(ops) ++ s.acc}
  defp new_label(s), do: {s.lbl, %{s | lbl: s.lbl + 1}}

  # dead code (after an unconditional br/return) — skip until a join label restores reachability. A block
  # defined entirely in dead code can't be a branch target from outside, so dropping it is safe.
  defp step(_instr, %{reachable: false} = s, _l), do: s

  # ── structured control flow (VOID constructs only; value-producing block/loop/if → :unsupported) ──

  defp step({:block, body}, s, l) do
    {lend, s} = new_label(s)
    frame = %{label: lend, entry: s.d, loop?: false}
    s1 = lower_seq(body, %{s | ctrl: [frame | s.ctrl]}, l)
    if s1.reachable and s1.d != frame.entry, do: throw(:unsupported)
    reach = s1.reachable or MapSet.member?(s1.used, lend)
    emit(%{s1 | ctrl: tl(s1.ctrl), d: frame.entry, reachable: reach}, [{:label, lend}])
  end

  defp step({:loop, body}, s, l) do
    {lstart, s} = new_label(s)
    s = emit(s, [{:label, lstart}])
    frame = %{label: lstart, entry: s.d, loop?: true}
    s1 = lower_seq(body, %{s | ctrl: [frame | s.ctrl]}, l)
    if s1.reachable and s1.d != frame.entry, do: throw(:unsupported)
    # after the loop, control continues iff the body fell through; depth resets to entry.
    %{s1 | ctrl: tl(s1.ctrl), d: frame.entry}
  end

  defp step({:if, then_b, else_b}, s, l) do
    if s.d < 1, do: throw(:unsupported)
    cond_reg = {:x, l + s.d - 1}
    d1 = s.d - 1
    {lelse, s} = new_label(s)
    {lend, s} = new_label(s)
    # is_ne_exact falls through when cond != 0 (→ then) and jumps to else when cond == 0.
    s = emit(s, [{:test, :is_ne_exact, {:f, lelse}, [cond_reg, {:integer, 0}]}])
    frame = %{label: lend, entry: d1, loop?: false}
    # then-branch (cond != 0)
    st = lower_seq(then_b, %{s | d: d1, reachable: true, ctrl: [frame | s.ctrl]}, l)
    if st.reachable and st.d != d1, do: throw(:unsupported)
    then_reach = st.reachable
    st = if then_reach, do: emit(st, [{:jump, {:f, lend}}]), else: st
    # else-branch (cond == 0)
    st = emit(st, [{:label, lelse}])
    se = lower_seq(else_b, %{st | d: d1, reachable: true}, l)
    if se.reachable and se.d != d1, do: throw(:unsupported)
    reach = then_reach or se.reachable or MapSet.member?(se.used, lend)
    emit(%{se | ctrl: tl(se.ctrl), d: d1, reachable: reach}, [{:label, lend}])
  end

  defp step({:br, n}, s, _l) do
    frame = Enum.at(s.ctrl, n) || throw(:unsupported)
    if frame.entry != s.d, do: throw(:unsupported)
    s = emit(s, [{:jump, {:f, frame.label}}])
    %{s | reachable: false, used: MapSet.put(s.used, frame.label)}
  end

  defp step({:br_if, n}, s, l) do
    if s.d < 1, do: throw(:unsupported)
    cond_reg = {:x, l + s.d - 1}
    d1 = s.d - 1
    frame = Enum.at(s.ctrl, n) || throw(:unsupported)
    if frame.entry != d1, do: throw(:unsupported)
    # br_if: branch to the target iff cond != 0. is_eq_exact falls through when cond == 0 (continue).
    s = emit(s, [{:test, :is_eq_exact, {:f, frame.label}, [cond_reg, {:integer, 0}]}])
    %{s | d: d1, used: MapSet.put(s.used, frame.label)}
  end

  defp step({:return}, s, l) do
    if s.d < 1, do: throw(:unsupported)
    s = emit(s, [{:move, {:x, l + s.d - 1}, {:x, 0}}, :return])
    %{s | reachable: false}
  end

  defp step({:i32_const, v}, s, l), do: %{emit(s, [{:move, {:integer, v &&& @mask32}, {:x, l + s.d}}]) | d: s.d + 1}

  defp step({:local_get, i}, s, l), do: %{emit(s, [{:move, {:x, i}, {:x, l + s.d}}]) | d: s.d + 1}

  defp step({:local_set, i}, s, l) do
    if s.d < 1, do: throw(:unsupported)
    %{emit(s, [{:move, {:x, l + s.d - 1}, {:x, i}}]) | d: s.d - 1}
  end

  defp step({:local_tee, i}, s, l) do
    if s.d < 1, do: throw(:unsupported)
    emit(s, [{:move, {:x, l + s.d - 1}, {:x, i}}])
  end

  defp step({:drop}, s, _l) do
    if s.d < 1, do: throw(:unsupported)
    %{s | d: s.d - 1}
  end

  defp step({:nop}, s, _l), do: s

  defp step({:op, opcode}, s, l) do
    cond do
      Map.has_key?(@binops, opcode) -> binop(opcode, s, l)
      Map.has_key?(@compares, opcode) -> compare(opcode, s, l)
      opcode == 0x45 -> eqz(s, l)
      true -> throw(:unsupported)
    end
  end

  defp step(_other, _s, _l), do: throw(:unsupported)

  defp binop(opcode, s, l) do
    if s.d < 2, do: throw(:unsupported)
    {beam_op, mask?} = @binops[opcode]
    a = {:x, l + s.d - 2}
    b = {:x, l + s.d - 1}
    dst = {:x, l + s.d - 2}
    live = l + s.d
    ops = [{:gc_bif, beam_op, {:f, 0}, live, [a, b], dst}]
    ops = if mask?, do: ops ++ [{:gc_bif, :band, {:f, 0}, live, [dst, {:integer, @mask32}], dst}], else: ops
    %{emit(s, ops) | d: s.d - 1}
  end

  # i32 comparison → a 0/1 value via test+branch.
  defp compare(opcode, s, l) do
    if s.d < 2, do: throw(:unsupported)
    {domain, test_op, swap?} = @compares[opcode]
    a = {:x, l + s.d - 2}
    b = {:x, l + s.d - 1}
    dst = {:x, l + s.d - 2}
    live = l + s.d
    # signed compares: convert both operands to signed-32 in place (branchless), then compare arithmetically.
    sconv = if domain == :s, do: s32_ops(a, live) ++ s32_ops(b, live), else: []
    args = if swap?, do: [b, a], else: [a, b]
    %{emit(s, sconv ++ branch01(test_op, args, dst, s)) | d: s.d - 1}
    |> bump_labels(2)
  end

  defp eqz(s, l) do
    if s.d < 1, do: throw(:unsupported)
    a = {:x, l + s.d - 1}
    %{emit(s, branch01(:is_eq_exact, [a, {:integer, 0}], a, s)) | d: s.d}
    |> bump_labels(2)
  end

  # branchless signed-32: s32(r) = ((r + 2^31) band 2^32-1) - 2^31, computed in place into r.
  defp s32_ops(r, live) do
    [
      {:gc_bif, :+, {:f, 0}, live, [r, {:integer, @sign}], r},
      {:gc_bif, :band, {:f, 0}, live, [r, {:integer, @mask32}], r},
      {:gc_bif, :-, {:f, 0}, live, [r, {:integer, @sign}], r}
    ]
  end

  # the value-producing comparison pattern: dst := 1 if (test passes / falls through) else 0. Uses the
  # CURRENT s.lbl and s.lbl+1 — callers MUST bump_labels(2) afterwards.
  defp branch01(test_op, args, dst, s) do
    lf = s.lbl
    le = s.lbl + 1
    [
      {:test, test_op, {:f, lf}, args},
      {:move, {:integer, 1}, dst},
      {:jump, {:f, le}},
      {:label, lf},
      {:move, {:integer, 0}, dst},
      {:label, le}
    ]
  end

  defp bump_labels(s, n), do: %{s | lbl: s.lbl + n}

  # build the from_asm 5-tuple {Mod, Exports, Attrs, Code, NumLabels}, compile in-memory, load native.
  defp assemble(gfidx, arity, body, num_labels) do
    mname = :"washy_asm_#{System.unique_integer([:positive])}"
    fname = :"wf_#{gfidx}"

    code = [
      {:function, fname, arity, 2,
       [
         {:label, 1},
         {:func_info, {:atom, mname}, {:atom, fname}, arity},
         {:label, 2}
         | body
       ]}
    ]

    asm = {mname, [{fname, arity}], [], code, num_labels}

    case :compile.forms(asm, [:from_asm, :binary, :return_errors]) do
      {:ok, ^mname, bin} ->
        {:module, ^mname} = :code.load_binary(mname, ~c"nofile", bin)
        {:ok, {mname, fname, arity}}

      {:ok, ^mname, bin, _warns} ->
        {:module, ^mname} = :code.load_binary(mname, ~c"nofile", bin)
        {:ok, {mname, fname, arity}}

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end

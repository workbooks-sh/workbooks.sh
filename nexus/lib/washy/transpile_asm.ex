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
      body = emit_body(instrs, l, arity, nlocals)
      assemble(gfidx, arity, l, body)
    else
      :unsupported
    end
  catch
    :unsupported -> :unsupported
  end

  # only (i32, …) -> (i32): every param and the single result is i32 (wasm valtype 0x7F = 127).
  defp supported_sig?(params, [127]), do: Enum.all?(params, &(&1 == 127))
  defp supported_sig?(_, _), do: false

  # fold the wasm body into BEAM-asm instructions, tracking operand-stack depth. reg(d) = {x, L+d}.
  defp emit_body(instrs, l, arity, nlocals) do
    zero = for i <- arity..(l - 1)//1, i >= arity, do: {:move, {:integer, 0}, {:x, i}}

    {rev, depth} =
      Enum.reduce(instrs, {Enum.reverse(zero), 0}, fn instr, {acc, d} ->
        step(instr, acc, d, l)
      end)

    unless depth == 1, do: throw(:unsupported)
    # result is the lone stack value at x(L); move it to x0 (skip if already there) and return.
    tail = if l == 0, do: [:return], else: [{:move, {:x, l}, {:x, 0}}, :return]
    Enum.reverse(rev) ++ tail
  end

  defp step({:i32_const, v}, acc, d, l),
    do: {[{:move, {:integer, v &&& @mask32}, {:x, l + d}} | acc], d + 1}

  defp step({:local_get, i}, acc, d, l),
    do: {[{:move, {:x, i}, {:x, l + d}} | acc], d + 1}

  defp step({:local_set, i}, acc, d, l) do
    nd = d - 1
    if nd < 0, do: throw(:unsupported)
    {[{:move, {:x, l + nd}, {:x, i}} | acc], nd}
  end

  defp step({:local_tee, i}, acc, d, l) do
    if d < 1, do: throw(:unsupported)
    {[{:move, {:x, l + d - 1}, {:x, i}} | acc], d}
  end

  defp step({:drop}, acc, d, _l) do
    if d < 1, do: throw(:unsupported)
    {acc, d - 1}
  end

  defp step({:nop}, acc, d, _l), do: {acc, d}

  defp step({:op, opcode}, acc, d, l) do
    case @binops do
      %{^opcode => {beam_op, mask?}} ->
        if d < 2, do: throw(:unsupported)
        a = {:x, l + d - 2}
        b = {:x, l + d - 1}
        dst = {:x, l + d - 2}
        live = l + d
        # `ops` is reverse-chronological (band prepended after add); `acc` is also reverse-chronological,
        # so prepend `ops` as-is — the final `Enum.reverse` restores add-then-band order.
        ops = [{:gc_bif, beam_op, {:f, 0}, live, [a, b], dst}]
        ops = if mask?, do: [{:gc_bif, :band, {:f, 0}, live, [dst, {:integer, @mask32}], dst} | ops], else: ops
        {ops ++ acc, d - 1}

      _ ->
        throw(:unsupported)
    end
  end

  defp step(_other, _acc, _d, _l), do: throw(:unsupported)

  # build the from_asm 5-tuple {Mod, Exports, Attrs, Code, NumLabels}, compile in-memory, load native.
  defp assemble(gfidx, arity, _l, body) do
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

    asm = {mname, [{fname, arity}], [], code, 3}

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

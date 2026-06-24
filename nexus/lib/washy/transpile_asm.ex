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
  @op_handlers [Nexus.Washy.AsmOps.Memory, Nexus.Washy.AsmOps.I64, Nexus.Washy.AsmOps.Floats, Nexus.Washy.AsmOps.IntExt, Nexus.Washy.AsmOps.Tables]

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
    case compile_module(mod, [gfidx]) do
      {:ok, _mname, map, [], _tok} -> {:ok, Map.fetch!(map, gfidx)}
      {:ok, _mname, _map, [^gfidx], _tok} -> :unsupported
      :none -> :unsupported
      _ -> :error
    end
  end

  @doc """
  **Compile a SET of functions into ONE shared BEAM module (wb-65ak — the atom-table wall fix).** Minting
  a unique module-name atom *per function* exhausts the (never-GC'd) atom table at scale; batching a whole
  guest module's functions into one BEAM module collapses atom growth from O(functions) to O(guest modules).
  Each function gets a disjoint label range. Returns `{:ok, module_atom, %{gfidx => {module, fun, arity}},
  unsupported_gfidxs, pool_token}` (the loaded native MFAs for the lowerable functions, plus the pool
  generation token to pin in the cache for recycle-detection), `:none` (none lowerable), or `:error`.
  """
  def compile_module(mod, gfidxs) do
    # Draw the module name from the FIXED recycled atom pool (atom-table wall fix). `:exhausted` means
    # every pool slot currently carries a live, in-execution module — fall back to interpreting this chunk
    # (the caller treats `:none` as "nothing lowered"), never minting an unbounded fresh atom.
    case Nexus.Washy.ModulePool.acquire() do
      {:ok, mname, tok} -> compile_module(mod, gfidxs, mname, tok)
      :exhausted -> :none
    end
  end

  defp compile_module(mod, gfidxs, mname, tok) do

    {funcs, exports, map, leftover, total} =
      Enum.reduce(gfidxs, {[], [], %{}, [], 0}, fn gfidx, {fs, exs, m, lo, off} ->
        case gen_function(mod, gfidx, mname) do
          {:ok, func, fname, arity, nlabels} ->
            # each function is generated standalone (labels 1..nlabels); shift its whole label range by
            # the labels already consumed so every function in the module is disjoint. Robust vs the
            # per-handler label threading (which is easy to get wrong → undefined_label).
            {[shift_func(func, off) | fs], [{fname, arity} | exs], Map.put(m, gfidx, {mname, fname, arity}), lo, off + nlabels}

          :unsupported ->
            {fs, exs, m, [gfidx | lo], off}
        end
      end)

    if funcs == [] do
      :none
    else
      asm = {mname, exports, [], Enum.reverse(funcs), total + 1}
      load_module(mname, asm, map, Enum.reverse(leftover), tok)
    end
  end

  # lower function `gfidx` standalone: labels 1 (func_info), 2 (entry), 3.. (body). Returns the function
  # tuple and the count of labels it uses (so the module assembler can shift it into a disjoint range).
  defp gen_function(mod, gfidx, mname) do
    ni = length(mod.imports)
    li = gfidx - ni
    {nlocals, instrs} = Enum.at(mod.code, li)
    {params, results} = Enum.at(mod.types, Enum.at(mod.funcs, li))
    arity = length(params)

    if supported_sig?(params, results) do
      l = arity + nlocals
      {body, next} = emit_body(instrs, l, arity, mod, ni, results)
      fname = :"wf_#{gfidx}"
      func =
        {:function, fname, arity, 2,
         [{:label, 1}, {:func_info, {:atom, mname}, {:atom, fname}, arity}, {:label, 2} | body]}

      # labels used = 1..(next-1) ⇒ (next-1) distinct labels.
      {:ok, func, fname, arity, next - 1}
    else
      :unsupported
    end
  catch
    :unsupported -> :unsupported
  end

  # Shift every label in a function tuple by `delta` (labels only appear as `{:label, N}` definitions and
  # `{:f, N}` references; `{:f, 0}` is "no fail label" and must NOT move; the entry is a bare integer).
  defp shift_func({:function, name, arity, entry, body}, delta),
    do: {:function, name, arity, entry + delta, Enum.map(body, &shift(&1, delta))}

  defp shift({:label, n}, d), do: {:label, n + d}
  defp shift({:f, 0}, _d), do: {:f, 0}
  defp shift({:f, n}, d), do: {:f, n + d}
  defp shift(t, d) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.map(&shift(&1, d)) |> List.to_tuple()
  defp shift(l, d) when is_list(l), do: Enum.map(l, &shift(&1, d))
  defp shift(x, _d), do: x

  defp load_module(mname, asm, map, leftover, tok) do
    case :compile.forms(asm, [:from_asm, :binary, :return_errors]) do
      {:ok, ^mname, bin} ->
        {:module, ^mname} = :code.load_binary(mname, ~c"nofile", bin)
        {:ok, mname, map, leftover, tok}

      {:ok, ^mname, bin, _warns} ->
        {:module, ^mname} = :code.load_binary(mname, ~c"nofile", bin)
        {:ok, mname, map, leftover, tok}

      other ->
        if System.get_env("WB_ASM_DEBUG"), do: IO.inspect({other, asm}, label: "asm-fail", limit: :infinity)
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # Accept any params over the scalar valtypes (i32=127, i64=126, f32=125, f64=124) and at most one
  # result. Values arrive/leave as Erlang terms (masked ints / floats) — the body op-handlers enforce the
  # actual op coverage, and bail :unsupported on anything they can't lower, so a permissive sig gate just
  # lets more functions be ATTEMPTED (the i32-only gate was the biggest coverage limiter). Multi-result
  # wasm returns (a tuple) are still out of scope.
  @valtypes [124, 125, 126, 127]
  defp supported_sig?(params, results) do
    length(results) <= 1 and Enum.all?(params, &(&1 in @valtypes)) and Enum.all?(results, &(&1 in @valtypes))
  end

  # State `s`: acc (reverse-chronological instrs), d (operand depth), maxd (max depth, sizes the frame),
  # lbl (next free label), reachable, ctrl (control-frame stack), used (labels some br targets), l (#locals).
  # Body labels start at 3 (func_info=1, entry=2). Returns {body, next_free_label}; the module assembler
  # shifts the whole function's label range to keep functions disjoint.
  defp emit_body(instrs, l, arity, mod, ni, results) do
    s0 = %{acc: [], d: 0, maxd: 0, lbl: 3, reachable: true, ctrl: [], used: %{}, l: l, mod: mod, ni: ni}
    s = lower_seq(instrs, s0)

    want = length(results)
    # The body may end REACHABLE (falls through with exactly `want` results on the stack — then we emit a
    # return tail) OR UNREACHABLE (every path already ended in a return/trap — no fall-through tail needed,
    # those emitted terminals are complete). Only reject a reachable body with the wrong stack height.
    if s.reachable and s.d != want, do: throw(:unsupported)
    frame = l + max(s.maxd, 1)
    # Prologue: allocate the frame, move params x→y, then zero-init EVERY remaining y-slot (declared
    # locals + operand-stack scratch). A call (charge_fuel/call_local) may GC and scans the whole frame,
    # so all y-slots must be initialized before the first call — even scratch slots written later.
    param_moves = for i <- 0..(arity - 1)//1, arity > 0, do: {:move, {:x, i}, {:y, i}}
    zero = for i <- arity..(frame - 1)//1, i >= arity, do: {:move, {:integer, 0}, {:y, i}}
    prologue = [{:allocate, frame, arity}] ++ param_moves ++ zero

    tail =
      cond do
        not s.reachable -> []
        want == 1 -> [{:move, {:y, l}, {:x, 0}}, {:deallocate, frame}, :return]
        true -> [{:move, {:integer, 0}, {:x, 0}}, {:deallocate, frame}, :return]
      end

    body = prologue ++ Enum.reverse(s.acc) ++ tail
    {patch_dealloc(body, frame), s.lbl}
  end

  defp patch_dealloc(body, frame), do: Enum.map(body, fn {:deallocate, :ph} -> {:deallocate, frame}; i -> i end)

  defp lower_seq(instrs, s), do: Enum.reduce(instrs, s, &step/2)

  # ── dead code: skip until a join label restores reachability ──
  defp step(_instr, %{reachable: false} = s), do: s

  # ── structured control flow. Supports VOID and SINGLE-RESULT block/loop/if (multi-value → :unsupported).
  # `used` is a map label→exit-depth: a `br`/`br_if` records the operand depth it carries to the target,
  # so a join's depth is known even when the body never falls through. All y-slots are zero-init'd up
  # front, so the validator never sees an uninitialized join register; correctness is just depth tracking.
  # A carried-result count (`delta`) must be 0 or 1. ──
  # A block/loop/if may carry up to @max_block_results values to its join. The slot model already handles
  # k>1: the k results occupy the top y-slots (y(l+entry)..y(l+entry+k-1)) on EVERY exit path (fall-through
  # and br), so depth tracking alone keeps them consistent — multi-value blocks just need a wider gate.
  @max_block_results 16
  defp ok_delta!(delta) when delta >= 0 and delta <= @max_block_results, do: :ok
  defp ok_delta!(_), do: throw(:unsupported)

  defp step({:block, body}, s) do
    {lend, s} = new_label(s)
    frame = %{label: lend, entry: s.d, loop?: false}
    s1 = lower_seq(body, %{s | ctrl: [frame | s.ctrl]})
    end_d = if s1.reachable, do: s1.d, else: Map.get(s1.used, lend, frame.entry)
    ok_delta!(end_d - frame.entry)
    reach = s1.reachable or Map.has_key?(s1.used, lend)
    emit(%{s1 | ctrl: tl(s1.ctrl), d: end_d, reachable: reach, used: Map.delete(s1.used, lend)}, [{:label, lend}])
  end

  defp step({:loop, body}, s) do
    {lstart, s} = new_label(s)
    # charge fuel on each iteration (entry) so a transpiled loop traps :out_of_fuel like the interpreter.
    s = emit(s, [{:label, lstart}, {:call_ext, 0, {:extfunc, @washy, :charge_fuel, 0}}])
    frame = %{label: lstart, entry: s.d, loop?: true}
    s1 = lower_seq(body, %{s | ctrl: [frame | s.ctrl]})
    end_d = if s1.reachable, do: s1.d, else: frame.entry
    ok_delta!(end_d - frame.entry)
    %{s1 | ctrl: tl(s1.ctrl), d: end_d, used: Map.delete(s1.used, lstart)}
  end

  defp step({:if, then_b, else_b}, s) do
    if s.d < 1, do: throw(:unsupported)
    d1 = s.d - 1
    {lelse, s} = new_label(s)
    {lend, s} = new_label(s)
    s = emit(s, [{:move, yd(s, s.d - 1), {:x, 0}}, {:test, :is_ne_exact, {:f, lelse}, [{:x, 0}, {:integer, 0}]}])
    frame = %{label: lend, entry: d1, loop?: false}
    st = lower_seq(then_b, %{s | d: d1, reachable: true, ctrl: [frame | s.ctrl]})
    then_reach = st.reachable
    then_d = if then_reach, do: st.d, else: Map.get(st.used, lend, d1)
    st = if then_reach, do: emit(st, [{:jump, {:f, lend}}]), else: st
    st = emit(st, [{:label, lelse}])
    se = lower_seq(else_b, %{st | d: d1, reachable: true})
    else_reach = se.reachable
    else_d = if else_reach, do: se.d, else: Map.get(se.used, lend, d1)
    # the two arms agree on result arity in valid wasm; take a reachable arm's depth (else a br's).
    end_d = cond do
      then_reach -> then_d
      else_reach -> else_d
      true -> Map.get(se.used, lend, d1)
    end
    ok_delta!(end_d - d1)
    reach = then_reach or else_reach or Map.has_key?(se.used, lend)
    emit(%{se | ctrl: tl(se.ctrl), d: end_d, reachable: reach, used: Map.delete(se.used, lend)}, [{:label, lend}])
  end

  defp step({:br, n}, s) do
    frame = Enum.at(s.ctrl, n) || throw(:unsupported)
    exit_d = if frame.loop?, do: frame.entry, else: s.d
    ok_delta!(exit_d - frame.entry)
    s = emit(s, [{:jump, {:f, frame.label}}])
    %{s | reachable: false, used: Map.put(s.used, frame.label, exit_d)}
  end

  defp step({:br_if, n}, s) do
    if s.d < 1, do: throw(:unsupported)
    d1 = s.d - 1
    frame = Enum.at(s.ctrl, n) || throw(:unsupported)
    exit_d = if frame.loop?, do: frame.entry, else: d1
    ok_delta!(exit_d - frame.entry)
    # branch to target iff cond != 0; is_eq_exact falls through (continue) when cond == 0.
    s = emit(s, [{:move, yd(s, s.d - 1), {:x, 0}}, {:test, :is_eq_exact, {:f, frame.label}, [{:x, 0}, {:integer, 0}]}])
    %{s | d: d1, used: Map.put(s.used, frame.label, exit_d)}
  end

  defp step({:return}, s) do
    if s.d < 1, do: throw(:unsupported)
    s = emit(s, [{:move, yd(s, s.d - 1), {:x, 0}}, {:deallocate, :ph}, :return])
    %{s | reachable: false}
  end

  # wasm `unreachable` (trap). Raise the SAME :unreachable trap the interpreter does, via the shared
  # seam. trap! never returns, but the validator can't know that — so emit a dead terminal (move/dealloc/
  # return) after it to keep every path well-formed + dealloc-balanced. Marks the path unreachable.
  defp step({:unreachable}, s) do
    s =
      emit(s, [
        {:move, {:atom, :unreachable}, {:x, 0}},
        {:call_ext, 1, {:extfunc, :"Elixir.Nexus.Washy.Trap", :trap!, 1}},
        {:move, {:integer, 0}, {:x, 0}},
        {:deallocate, :ph},
        :return
      ])

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
    # Any scalar (i32/i64/f32/f64) args/result, single result max. Values cross the call_local trampoline
    # as Erlang terms regardless of wasm type, so the type doesn't matter to us — only the arity does.
    # (Multi-result returns a list the asm caller can't place → still :unsupported.)
    unless Enum.all?(params, &(&1 in @valtypes)) and Enum.all?(results, &(&1 in @valtypes)) and nr <= 1, do: throw(:unsupported)
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
end

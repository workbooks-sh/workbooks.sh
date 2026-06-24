defmodule Nexus.Washy.AsmOps.Tables do
  @moduledoc """
  **Table-driven ops for the BEAM-assembly lane (`Nexus.Washy.TranspileAsm`).** Two ops:

    * `{:br_table, labels, default}` — multi-way branch on a popped i32 index. Bit-identical to the
      interpreter (`Nexus.Washy.step({:br_table, …})`): `target = if i < length(labels), do: labels[i],
      else: default`. Each target is a relative control-depth into `s.ctrl`; we lower to a BEAM
      `select_val` over the index that jumps to per-target trampoline labels, each of which jumps to the
      target control frame's BEAM label — recording the carried exit-depth in `s.used` exactly as the
      built-in `{:br}` step does. `br_table` is an UNCONDITIONAL multi-way branch ⇒ `reachable: false`.

      Scope: **void br_table only** (carried arity 0 for every target). A result-carrying br_table
      (any target whose `exit_d != entry`) → `:unsupported` (caller falls back to the forms lane). This
      is the common case and keeps the lowering provably correct without a value-move dance that would
      have to agree across all targets.

    * `{:call_indirect, typeidx}` — pop a table index, resolve the function in the module table AT
      RUNTIME, call it on the shared run state. We don't know the table contents statically here, so we
      load the popped index + the arg list and `call_ext` `Nexus.Washy.call_indirect_dyn/3`, a thin
      public mirror of the interpreter's `{:call_indirect}` step (same `:undefined_element` /
      `:indirect_call_type_mismatch` traps, same `call_fn` dispatch on the shared `:washy_rt`). That is
      the cleanest bit-identical path — one seam, the interpreter's exact dispatch + trap behaviour.

      Scope: i32-only params/results, ≤1 result (matches the direct-`call` step's gate).
  """
  import Nexus.Washy.AsmCtx

  @doc "Op-group handler. `{:ok, s}` if handled, `:unsupported` otherwise."
  def handle({:br_table, labels, default}, s), do: br_table(labels, default, s)
  def handle({:call_indirect, typeidx}, s), do: call_indirect(typeidx, s)
  def handle(_instr, _s), do: :unsupported

  # ── br_table ───────────────────────────────────────────────────────────────────────────────────────
  defp br_table(_labels, _default, %{d: d}) when d < 1, do: :unsupported

  defp br_table(labels, default, s) do
    targets = labels ++ [default]
    ctrl = s.ctrl

    # resolve every target frame (relative control-depths)
    frames = Enum.map(targets, &Enum.at(ctrl, &1))

    # the index is the top operand; after the pop the operand depth is d1
    d1 = s.d - 1

    cond do
      Enum.any?(frames, &is_nil/1) ->
        :unsupported

      # VOID-only: every target must carry 0 (exit_d == entry). loop frames carry `entry`; others carry
      # the post-pop depth d1, so require d1 == entry for them.
      not Enum.all?(frames, fn f -> (if f.loop?, do: f.entry, else: d1) == f.entry end) ->
        :unsupported

      true ->
        emit_br_table(frames, s, d1)
    end
  end

  defp emit_br_table(frames, s, d1) do
    # default target = the LAST frame (`default`); the others map to index 0..n-1.
    {label_frames, [default_frame]} = Enum.split(frames, length(frames) - 1)

    # one trampoline label per indexed entry → jumps to its control frame's BEAM label.
    {tramps, s} =
      Enum.map_reduce(label_frames, s, fn f, acc ->
        {tl, acc} = new_label(acc)
        {{f, tl}, acc}
      end)

    {default_tl, s} = new_label(s)

    # select_val list: [0, {:f, Tramp0}, 1, {:f, Tramp1}, ...]
    sv_list =
      tramps
      |> Enum.with_index()
      |> Enum.flat_map(fn {{_f, tl}, i} -> [{:integer, i}, {:f, tl}] end)

    move_idx = {:move, yd(s, s.d - 1), {:x, 0}}
    select = {:select_val, {:x, 0}, {:f, default_tl}, {:list, sv_list}}

    tramp_code =
      Enum.flat_map(tramps, fn {f, tl} -> [{:label, tl}, {:jump, {:f, f.label}}] end) ++
        [{:label, default_tl}, {:jump, {:f, default_frame.label}}]

    s = emit(s, [move_idx, select] ++ tramp_code)

    # record each distinct target frame label in `s.used` with its carried exit-depth (0-carry/void).
    used =
      Enum.reduce(frames, s.used, fn f, acc ->
        exit_d = if f.loop?, do: f.entry, else: d1
        Map.put(acc, f.label, exit_d)
      end)

    {:ok, %{s | d: d1, reachable: false, used: used}}
  end

  # ── call_indirect ────────────────────────────────────────────────────────────────────────────────
  defp call_indirect(_typeidx, %{d: d}) when d < 1, do: :unsupported

  defp call_indirect(typeidx, s) do
    {params, results} = Enum.at(s.mod.types, typeidx)
    np = length(params)
    nr = length(results)

    cond do
      # any scalar (i32/i64/f32/f64) args/result, ≤1 result — values cross call_indirect_dyn as Erlang
      # terms regardless of wasm type, so only the arity matters (matches the relaxed direct-call gate).
      not (Enum.all?(params, &(&1 in [124, 125, 126, 127])) and Enum.all?(results, &(&1 in [124, 125, 126, 127])) and nr <= 1) ->
        :unsupported

      s.d < np + 1 ->
        :unsupported

      true ->
        emit_call_indirect(typeidx, np, nr, s)
    end
  end

  defp emit_call_indirect(typeidx, np, nr, s) do
    # stack (top → bottom): [index, arg(np-1), ..., arg0, ...]. Build the arg list from the np slots
    # BELOW the index (a depth view with the index excluded), then load the index and call the seam.
    s_args = %{s | d: s.d - 1}
    build = build_arglist(s_args, np)

    # build/2 leaves the arg list in x1; stash it in x2, then x0 := index, x1 := typeidx, call seam.
    call = [
      {:move, {:x, 1}, {:x, 2}},
      {:move, yd(s, s.d - 1), {:x, 0}},
      {:move, {:integer, typeidx}, {:x, 1}},
      {:call_ext, 3, {:extfunc, washy(), :call_indirect_dyn, 3}}
    ]

    # pop the index AND the np args
    s2 = %{s | d: s.d - 1 - np}

    if nr == 1 do
      {:ok, push(emit(s2, build ++ call ++ [{:move, {:x, 0}, yd(s2, s2.d)}]))}
    else
      {:ok, emit(s2, build ++ call)}
    end
  end

  # build the Erlang arg list [arg0, …, arg(np-1)] (call order) into x1 from the top np operand slots of
  # `s`. Mirrors TranspileAsm.build_arglist/2.
  defp build_arglist(_s, 0), do: [{:move, nil, {:x, 1}}]

  defp build_arglist(s, np) do
    puts =
      for p <- (np - 1)..0//-1 do
        tail = if p == np - 1, do: nil, else: {:x, 1}
        [{:move, yd(s, s.d - np + p), {:x, 0}}, {:put_list, {:x, 0}, tail, {:x, 1}}]
      end

    [{:test_heap, 2 * np, 0} | List.flatten(puts)]
  end
end

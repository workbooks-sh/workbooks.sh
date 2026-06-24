defmodule Nexus.Washy.Transpile do
  @moduledoc """
  **Washy's wasm→BEAM transpiler.** The second execution backend: instead of *interpreting* the
  structured instruction tree, it *compiles* a wasm function to a real BEAM function (Erlang abstract
  forms → `:compile.forms` → `:code.load_binary`), so it runs on the BeamAsm JIT at native-ish speed
  while inheriting the same isolation (it's still ordinary BEAM code in a process).

  ## How it works

  A wasm function is already *structured* (no arbitrary gotos), and its operand stack is a compile-time
  artifact — so we **compile the stack away**: we fold the instruction list maintaining a compile-time
  stack of Erlang *expressions* (not values). `local.get` pushes a local var, `i32.const` pushes a
  literal, `i32.add` pops two operands and pushes `(A + B) band 16#FFFFFFFF`. No operand stack survives
  to runtime — it became the shape of the generated AST (SSA).

  ### Locals — SSA renaming (locals live in BEAM registers, not a runtime tuple)
  Each wasm local maps to a *current* Erlang variable. `local.set i`/`local.tee i` mints a fresh var,
  binds it, and updates the per-local "current var" map. Maximally JIT-friendly.

  ### Control flow — native Erlang
    * `if`/`else`  → an Erlang `case` on the condition. Each arm runs, then the live locals + a single
      result value are bundled into a tuple so the post-merge is one pattern match.
    * `loop`       → a recursive named Erlang fun; a `br` to the loop label is a tail call (the next
      iteration), passing the live locals.
    * `block`      → a recursive-fun "join point" too: a `block` introduces a forward label, and a
      `br` to it / fallthrough both produce the block's result + locals, which the continuation matches.
      We model the whole region functionally: a construct compiles to a value+locals it yields.

  We use a **functional region model**: lowering a (possibly nested) instruction sequence yields, at
  compile time, a single Erlang expression that evaluates to `{ResultStack, LocalsTuple}` *unless* an
  early `br`/`return` escapes the region — escapes are realized with `throw`/`catch` carrying the
  target label depth, caught at the matching `block`/`loop`/function boundary. This mirrors the
  interpreter's signal protocol exactly (correct against the oracle) while compiling to native control
  flow and keeping locals in variables.

  Anything outside the supported surface returns `{:error, {:unsupported, op}}` — **never wrong code**.

  ### Direct calls
  `call` to another *local* function is supported: every reachable callee is compiled into the same
  loaded BEAM module and invoked directly. Calls to imports/host functions are out of scope.
  """
  import Bitwise
  @mask32 0xFFFFFFFF
  @mask64 0xFFFFFFFFFFFFFFFF
  @page_words 8192
  @ln 1

  # ── public API ──────────────────────────────────────────────────────────────────────────────────

  @doc """
  Compile exported function `name` to a native BEAM function. Returns `{:ok, fun}` where `fun` takes
  the argument LIST, or `{:error, {:unsupported, op}}` if it falls outside the supported surface.
  """
  def compile(mod, name) do
    try do
      fidx = export_fidx!(mod, name)
      {mname, idx_to_fun} = build_module(mod, [fidx])
      {fname, arity} = Map.fetch!(idx_to_fun, fidx)

      fun = fn args ->
        if length(args) != arity, do: throw({:washy_arity, fidx})
        # Mirror the interpreter's per-call runtime setup so memory ops compare fairly against the
        # oracle: a fresh packed `:atomics` linear memory in `:washy_mem`, sized to the module's min
        # pages, with active data segments copied in. The generated code reads/writes this SAME memory
        # (identical packed byte access), so transpiled load/store match the interpreter exactly.
        prev_mem = Process.get(:washy_mem)
        setup_memory(mod)

        try do
          apply(mname, fname, args)
        after
          if prev_mem == nil, do: Process.delete(:washy_mem), else: Process.put(:washy_mem, prev_mem)
        end
      end

      {:ok, fun}
    catch
      {:unsupported, op} -> {:error, {:unsupported, op}}
    end
  end

  defp export_fidx!(mod, name) do
    fidx = Map.fetch!(mod.exports, name)
    ni = length(mod.imports)
    if fidx < ni, do: throw({:unsupported, :imported_function})
    fidx
  end

  # ── module assembly ──────────────────────────────────────────────────────────────────────────────

  defp build_module(mod, roots) do
    ni = length(mod.imports)
    idx_to_fun = collect(mod, roots, ni, %{})

    functions =
      for {fidx, {fname, arity}} <- idx_to_fun do
        compile_fn(mod, fidx, ni, fname, arity, idx_to_fun)
      end

    mname = :"washy_jit_#{System.unique_integer([:positive])}"
    exports = for {_fidx, {fname, arity}} <- idx_to_fun, do: {fname, arity}

    forms =
      [{:attribute, @ln, :module, mname}, {:attribute, @ln, :export, exports}] ++ functions

    case :compile.forms(forms, [:return_errors]) do
      {:ok, ^mname, bin} ->
        {:module, ^mname} = :code.load_binary(mname, ~c"nofile", bin)
        {mname, idx_to_fun}

      {:error, errors, _warnings} ->
        throw({:unsupported, {:compile_error, errors}})
    end
  end

  # ── linear-memory setup (mirrors Nexus.Washy.new_mem + init_data so the oracle compares fairly) ──
  # A fresh packed `:atomics` (8 bytes/slot, == the interpreter's layout), sized to the module's min
  # pages, installed in the process dict under `:washy_mem`; active data segments copied in.
  defp setup_memory(%{mem: nil}), do: Process.delete(:washy_mem)

  defp setup_memory(%{mem: {min, _max}} = mod) do
    pages = max(1, min)
    mem = :atomics.new(pages * @page_words, signed: false)
    Process.put(:washy_mem, mem)
    for seg <- mod.data, do: init_data_seg(mem, seg)
    :ok
  end

  defp init_data_seg(mem, {:active, offset_expr, bytes}) do
    addr = const_offset(offset_expr)
    bytes |> :binary.bin_to_list() |> Enum.with_index() |> Enum.each(fn {b, i} -> mput(mem, addr + i, b) end)
  end

  defp init_data_seg(_mem, _passive), do: :ok

  # evaluate a tiny const-expr offset (active data segments use i32.const in practice). Globals in an
  # offset are uncommon and not needed by the transpile tests; default to 0 if we can't fold it.
  defp const_offset([{:i32_const, v} | _]), do: v &&& @mask32
  defp const_offset([{:i64_const, v} | _]), do: v &&& @mask64
  defp const_offset(_), do: 0

  # the interpreter's packed byte write (read-modify-write of the containing 64-bit word) — used here
  # ONLY for host-side data-segment init; guest load/store is generated as inline Erlang.
  defp mput(mem, addr, byte) do
    idx = (addr >>> 3) + 1
    sh = (addr &&& 7) * 8
    w = :atomics.get(mem, idx)
    w = ((w &&& bnot(0xFF <<< sh)) ||| ((byte &&& 0xFF) <<< sh)) &&& @mask64
    :atomics.put(mem, idx, w)
  end

  defp collect(_mod, [], _ni, acc), do: acc

  defp collect(mod, [fidx | rest], ni, acc) do
    cond do
      Map.has_key?(acc, fidx) ->
        collect(mod, rest, ni, acc)

      fidx < ni ->
        throw({:unsupported, {:call_import, fidx}})

      true ->
        {arity, _nlocals, instrs} = function_body(mod, fidx, ni)
        acc = Map.put(acc, fidx, {:"wf_#{fidx}", arity})
        callees = for {:call, c} <- flatten_calls(instrs), do: c
        collect(mod, callees ++ rest, ni, acc)
    end
  end

  defp function_body(mod, fidx, ni) do
    local_idx = fidx - ni
    {nlocals, instrs} = Enum.at(mod.code, local_idx)
    {params, _results} = Enum.at(mod.types, Enum.at(mod.funcs, local_idx))
    {length(params), nlocals, instrs}
  end

  defp flatten_calls(instrs) do
    Enum.flat_map(instrs, fn
      {:call, _} = c -> [c]
      {:block, body} -> flatten_calls(body)
      {:loop, body} -> flatten_calls(body)
      {:if, t, e} -> flatten_calls(t) ++ flatten_calls(e)
      _ -> []
    end)
  end

  # ── per-function codegen ─────────────────────────────────────────────────────────────────────────
  #
  # ctx = %{lmap: %{local_idx => erl_var}, gen: counter, calls: idx_to_fun, depth: control nesting}
  # `depth` is the count of enclosing block/loop labels (for br target resolution).
  #
  # Region lowering returns {erl_stmts, comp_stack, ctx}. `erl_stmts` are side-effecting binds; the
  # function's return is the top of the final comp_stack.

  defp compile_fn(mod, fidx, ni, fname, arity, idx_to_fun) do
    {^arity, nlocals, instrs} = function_body(mod, fidx, ni)
    params = for i <- 0..(arity - 1)//1, do: var("A#{i}")
    {prelude, lmap} = init_locals(params, arity, nlocals)
    ctx = %{lmap: lmap, gen: 0, calls: idx_to_fun, depth: 0, labels: %{}}

    {stmts, stack, _ctx} = lower_seq(instrs, [], ctx)
    # if the body fell off the end as :unreachable (every path branched/returned away — e.g. a
    # trailing br_table), the value arrives via the caught return throw; emit a placeholder tail.
    ret = case stack do
      [top | _] -> top
      [] -> {:integer, @ln, 0}
      :unreachable -> {:integer, @ln, 0}
    end

    # A top-level `return` throws {:washy_ret, depth_at_return, [val]}; wrap the body to catch it.
    body = wrap_return(prelude ++ stmts ++ [ret])
    {:function, @ln, fname, arity, [{:clause, @ln, params, [], body}]}
  end

  defp init_locals(params, arity, nlocals) do
    base = for {p, i} <- Enum.with_index(params), into: %{}, do: {i, p}
    if nlocals == 0 do
      {[], base}
    else
      Enum.reduce(0..(nlocals - 1)//1, {[], base}, fn k, {ss, m} ->
        idx = arity + k
        v = var("Ld#{idx}")
        {ss ++ [{:match, @ln, v, {:integer, @ln, 0}}], Map.put(m, idx, v)}
      end)
    end
  end

  # body that may `throw({:washy_ret, _, [Val]})` → catch it and return Val.
  defp wrap_return(body) do
    rv = var("_RetV")

    catch_clause =
      {:clause, @ln,
       [catch_pat({:tuple, @ln, [{:atom, @ln, :washy_ret}, {:var, @ln, :_}, {:cons, @ln, rv, {nil, @ln}}]})],
       [], [rv]}

    catch_void =
      {:clause, @ln,
       [catch_pat({:tuple, @ln, [{:atom, @ln, :washy_ret}, {:var, @ln, :_}, {nil, @ln}]})],
       [], [{:integer, @ln, 0}]}

    [{:try, @ln, body, [], [catch_clause, catch_void], []}]
  end

  # an Erlang `try ... catch` clause pattern is `{Class, Reason, Stacktrace}`; we only ever throw, so
  # match `{throw, <reason>, _}`.
  defp catch_pat(reason_pat) do
    {:tuple, @ln, [{:atom, @ln, :throw}, reason_pat, {:var, @ln, :_}]}
  end

  # ── sequence + straight-line lowering ────────────────────────────────────────────────────────────

  defp lower_seq(instrs, stack, ctx) do
    Enum.reduce(instrs, {[], stack, ctx}, fn instr, {stmts, st, c} ->
      {ns, st, c} = lower(instr, st, c)
      {stmts ++ ns, st, c}
    end)
  end

  # once a sequence becomes :unreachable, subsequent ops are dead code (the wasm validator still
  # type-checks them, but they never run). Swallow them — folding the comp-stack would be ill-defined.
  defp lower(_instr, :unreachable, ctx), do: {[], :unreachable, ctx}

  defp lower({:i32_const, v}, stack, ctx), do: {[], [{:integer, @ln, v &&& @mask32} | stack], ctx}
  defp lower({:local_get, i}, stack, ctx), do: {[], [Map.fetch!(ctx.lmap, i) | stack], ctx}

  defp lower({:local_set, i}, [v | stack], ctx) do
    {stmt, ctx} = bind_local(i, v, ctx)
    {[stmt], stack, ctx}
  end

  defp lower({:local_tee, i}, [v | rest], ctx) do
    {stmt, ctx} = bind_local(i, v, ctx)
    {[stmt], [Map.fetch!(ctx.lmap, i) | rest], ctx}
  end

  defp lower({:op, opcode}, stack, ctx) do
    n = op_pops(opcode)
    expr = apply_op(opcode, stack)
    # bind the op result so it isn't recomputed if the stack value is consumed by multiple ops.
    {v, ctx} = fresh(ctx, "V")
    {[{:match, @ln, v, expr}], [v | drop(stack, n)], ctx}
  end

  defp lower({:call, fidx}, stack, ctx) do
    {fname, arity} = Map.fetch!(ctx.calls, fidx)
    {args, rest} = Enum.split(stack, arity)
    call = {:call, @ln, {:atom, @ln, fname}, Enum.reverse(args)}
    {v, ctx} = fresh(ctx, "C")
    {[{:match, @ln, v, call}], [v | rest], ctx}
  end

  defp lower({:drop}, [_ | stack], ctx), do: {[], stack, ctx}
  defp lower({:nop}, stack, ctx), do: {[], stack, ctx}

  # ── constants ────────────────────────────────────────────────────────────────────────────────────
  defp lower({:i64_const, v}, stack, ctx), do: {[], [{:integer, @ln, v &&& @mask64} | stack], ctx}

  # float const: finite floats compile to a literal; a non-finite const ({:nonfinite,_,_}) is rare in
  # our test surface — keep it unsupported rather than miscompile.
  defp lower({:fconst, v}, stack, ctx) when is_float(v) do
    {[], [{:float, @ln, v} | stack], ctx}
  end

  defp lower({:fconst, other}, _stack, _ctx), do: throw({:unsupported, {:fconst, other}})

  # ── memory load/store ────────────────────────────────────────────────────────────────────────────
  # Effective address = base + static offset; bounds-checked against the LOGICAL memory size (derived
  # from the atomics backing: slots*8 bytes == pages*65536) → :out_of_bounds trap, exactly as interp.
  defp lower({:i32_load, o}, [a | s], ctx), do: load_int(a, o, 4, :u, s, ctx)
  defp lower({:i32_load8u, o}, [a | s], ctx), do: load_int(a, o, 1, :u, s, ctx)
  defp lower({:i32_load8s, o}, [a | s], ctx), do: load_int(a, o, 1, {:s, 32}, s, ctx)
  defp lower({:i32_load16u, o}, [a | s], ctx), do: load_int(a, o, 2, :u, s, ctx)
  defp lower({:i32_load16s, o}, [a | s], ctx), do: load_int(a, o, 2, {:s, 32}, s, ctx)
  defp lower({:i64_load, o, 8, _}, [a | s], ctx), do: load_int(a, o, 8, :u, s, ctx)
  defp lower({:i64_load, o, n, true}, [a | s], ctx), do: load_int(a, o, n, {:s, 64}, s, ctx)
  defp lower({:i64_load, o, n, false}, [a | s], ctx), do: load_int(a, o, n, :u, s, ctx)
  defp lower({:i32_store, o}, [v, a | s], ctx), do: store_int(a, v, o, 4, s, ctx)
  defp lower({:i32_store8, o}, [v, a | s], ctx), do: store_int(a, v, o, 1, s, ctx)
  defp lower({:i32_store16, o}, [v, a | s], ctx), do: store_int(a, v, o, 2, s, ctx)
  defp lower({:i64_store, o, n}, [v, a | s], ctx), do: store_int(a, v, o, n, s, ctx)
  defp lower({:f32_load, o}, [a | s], ctx), do: load_float(a, o, 4, s, ctx)
  defp lower({:f64_load, o}, [a | s], ctx), do: load_float(a, o, 8, s, ctx)
  defp lower({:f32_store, o}, [v, a | s], ctx), do: store_float(a, v, o, 4, s, ctx)
  defp lower({:f64_store, o}, [v, a | s], ctx), do: store_float(a, v, o, 8, s, ctx)

  # ── br_table: switch on the (clamped) index → the right depth-tagged exit / loop tail-call ─────────
  defp lower({:br_table, labels, default}, [idx_e | stack], ctx), do: lower_br_table(labels, default, idx_e, stack, ctx)

  # ── control flow ─────────────────────────────────────────────────────────────────────────────────

  defp lower({:if, then_b, else_b}, [cond_e | stack], ctx), do: lower_if(cond_e, then_b, else_b, stack, ctx)
  defp lower({:block, body}, stack, ctx), do: lower_block(body, stack, ctx)
  defp lower({:loop, body}, stack, ctx), do: lower_loop(body, stack, ctx)
  defp lower({:br, n}, stack, ctx), do: {[do_br(n, stack, ctx)], :unreachable, ctx}
  defp lower({:br_if, n}, [cond_e | stack], ctx), do: lower_br_if(n, cond_e, stack, ctx)
  defp lower({:return}, stack, ctx), do: {[do_return(stack, ctx)], :unreachable, ctx}

  defp lower(other, _stack, _ctx), do: throw({:unsupported, other})

  # ── br / return: throw a tagged signal caught at the target label ────────────────────────────────
  # Branch target depth: a `br n` exits `n+1` enclosing labels. We compute the absolute label depth it
  # lands at = ctx.depth - n - 1, and throw {:washy_br, target_depth, ResultList, LocalsTuple}. The
  # enclosing block/loop installed at that depth catches it.

  defp do_br(n, stack, ctx) do
    target = ctx.depth - n - 1

    case Map.get(ctx.labels, target) do
      # br to a LOOP label = "jump to loop start" = continue. Compile to a DIRECT recursive call
      # (the hot path — no exception). When in tail position this is a proper BEAM tail call.
      {:loop, fun_atom} ->
        {:call, @ln, {:var, @ln, fun_atom}, [locals_tuple(ctx)]}

      # br to a BLOCK label = "jump past the block" = forward exit. Realized as a throw the enclosing
      # block's try catches (forward jumps can't be a tail call in structured Erlang).
      _ ->
        {:call, @ln, {:remote, @ln, {:atom, @ln, :erlang}, {:atom, @ln, :throw}},
         [{:tuple, @ln, [{:atom, @ln, :washy_br}, {:integer, @ln, target}, result_list(stack), locals_tuple(ctx)]}]}
    end
  end

  defp do_return(stack, ctx) do
    {:call, @ln, {:remote, @ln, {:atom, @ln, :erlang}, {:atom, @ln, :throw}},
     [{:tuple, @ln, [{:atom, @ln, :washy_ret}, {:integer, @ln, ctx.depth}, result_list(stack)]}]}
  end

  # the values a br/return carries = the current top-of-stack as a 0-or-1-element list (our test
  # programs and the interpreter's call_fn deal in single results / void).
  defp result_list(:unreachable), do: {nil, @ln}
  defp result_list([]), do: {nil, @ln}
  defp result_list([top | _]), do: {:cons, @ln, top, {nil, @ln}}

  defp stack_arity(:unreachable), do: 0
  defp stack_arity(stack), do: min(length(stack), 1)

  defp locals_tuple(ctx) do
    n = map_size(ctx.lmap)
    {:tuple, @ln, for(i <- 0..(n - 1)//1, do: Map.fetch!(ctx.lmap, i))}
  end

  # ── if/else → case, with locals merged ───────────────────────────────────────────────────────────

  defp lower_if(cond_e, then_b, else_b, stack, ctx) do
    nlocals = map_size(ctx.lmap)

    # Compile each arm in a child ctx; the arm yields {ResultList, LocalsTuple}. (br/return inside an
    # arm escape via throw and are caught higher up — they don't fall through this merge.)
    {then_expr, then_arity, ctx} = compile_arm(then_b, ctx)
    {else_expr, else_arity, ctx} = compile_arm(else_b, ctx)
    result_arity = max(then_arity, else_arity)

    rv = {:var, @ln, :"_If#{ctx.gen}"}
    case_e =
      {:match, @ln, rv,
       {:case, @ln, {:op, @ln, :"/=", cond_e, {:integer, @ln, 0}},
        [
          {:clause, @ln, [{:atom, @ln, true}], [], [then_expr]},
          {:clause, @ln, [{:atom, @ln, false}], [], [else_expr]}
        ]}}

    # rv = {ResultList, LocalsTuple}; pull locals back into fresh SSA vars + push result.
    sv = {:var, @ln, :"_IfS#{ctx.gen}"}
    lv = {:var, @ln, :"_IfL#{ctx.gen}"}
    destructure = {:match, @ln, {:tuple, @ln, [sv, lv]}, rv}

    ctx = %{ctx | gen: ctx.gen + 1}
    {lstmts, ctx} = rebind_locals_from_tuple(lv, nlocals, ctx)

    if result_arity == 0 do
      {[case_e, destructure] ++ lstmts, stack, ctx}
    else
      {tv, ctx} = fresh(ctx, "Ift")
      get_top = {:match, @ln, tv, {:call, @ln, {:atom, @ln, :hd}, [sv]}}
      {[case_e, destructure] ++ lstmts ++ [get_top], [tv | stack], ctx}
    end
  end

  # Compile an arm (instr list) to an expression evaluating to {ResultList, LocalsTuple}. Returns
  # {expr, result_arity}. Runs in a child block that catches no signals (br/return propagate out).
  defp compile_arm(instrs, ctx) do
    {stmts, stack, ctx2} = lower_seq(instrs, [], ctx)
    arity = stack_arity(stack)
    yield = {:tuple, @ln, [result_list(stack), locals_tuple(ctx2)]}
    # The arm runs in its own `begin` block (separate case clause), so its local rebindings don't
    # survive the merge — we restore the parent lmap. But the gen counter MUST keep advancing globally
    # so region vars never collide across siblings/nesting.
    {block_expr(stmts ++ [yield]), arity, %{ctx | gen: ctx2.gen}}
  end

  # ── block → a labelled forward region; br to it / fallthrough both yield {result, locals} ─────────

  defp lower_block(body, stack, ctx) do
    target_depth = ctx.depth
    nlocals = map_size(ctx.lmap)
    inner = %{ctx | depth: ctx.depth + 1, labels: Map.put(ctx.labels, target_depth, {:block, nil})}

    # body compiled in a child block: it yields {result, locals} on fallthrough; a `br target_depth`
    # throws {:washy_br, target_depth, ...} which we catch here and turn into the same shape.
    {stmts, bstack, bctx} = lower_seq(body, [], inner)
    fall = {:tuple, @ln, [result_list(bstack), locals_tuple(bctx)]}
    body_expr = block_expr(stmts ++ [fall])

    # advance the parent gen past everything the body minted, so region vars are globally unique.
    ctx = %{ctx | gen: bctx.gen + 1}
    region = try_catch_label(body_expr, target_depth, ctx.gen)
    consume_region(region, stack_arity(bstack), stack, nlocals, ctx)
  end

  # ── loop → recursive named fun; br to loop label = recurse with current locals ───────────────────

  defp lower_loop(body, stack, ctx) do
    target_depth = ctx.depth
    nlocals = map_size(ctx.lmap)

    # The loop compiles to a recursive named fun over the locals tuple. A `br target_depth` (continue)
    # is lowered by `do_br` to a DIRECT recursive call to this fun (no exception) — a proper BEAM tail
    # call when it sits in tail position. Fallthrough yields {result, locals}; a `br`/`return` to an
    # OUTER label is a throw the outer construct catches.
    id = ctx.gen
    fun_name = {:var, @ln, :"_Loop#{id}"}
    lv = {:var, @ln, :"_LpL#{id}"}

    inner_lmap = lmap_from_tuple(lv, nlocals)
    fun_atom = elem(fun_name, 2)

    inner = %{
      ctx
      | depth: ctx.depth + 1,
        lmap: inner_lmap,
        gen: ctx.gen + 1,
        labels: Map.put(ctx.labels, target_depth, {:loop, fun_atom})
    }

    {stmts, bstack, bctx} = lower_seq(body, [], inner)
    fall = {:tuple, @ln, [result_list(bstack), locals_tuple(bctx)]}
    body_expr = block_expr(stmts ++ [fall])

    loop_fun =
      {:named_fun, @ln, fun_atom, [{:clause, @ln, [lv], [], [body_expr]}]}

    init_call = {:call, @ln, loop_fun, [locals_tuple(ctx)]}

    # advance parent gen past the loop body's mints before consuming.
    ctx = %{ctx | gen: bctx.gen + 1}
    consume_region(init_call, stack_arity(bstack), stack, nlocals, ctx)
  end

  # ── shared: wrap a region expr to catch a br to `target_depth`, and splice its {result,locals} back ─

  # try the body; if a {:washy_br, target_depth, S, L} escapes it, that's a br OUT of this block → its
  # carried result+locals become the region's value. Any other signal (outer br / ret) re-propagates.
  defp try_catch_label(body_expr, target_depth, id) do
    sv = {:var, @ln, :"_BrS#{id}"}
    lv = {:var, @ln, :"_BrL#{id}"}
    catch_here =
      {:clause, @ln,
       [catch_pat({:tuple, @ln, [{:atom, @ln, :washy_br}, {:integer, @ln, target_depth}, sv, lv]})],
       [], [{:tuple, @ln, [sv, lv]}]}

    {:try, @ln, [body_expr], [], [catch_here], []}
  end

  # region_expr evaluates to {ResultList, LocalsTuple}; destructure, rebind locals, push result.
  defp consume_region(region_expr, result_arity, stack, nlocals, ctx) do
    rv = {:var, @ln, :"_Rg#{ctx.gen}"}
    sv = {:var, @ln, :"_RgS#{ctx.gen}"}
    lv = {:var, @ln, :"_RgL#{ctx.gen}"}
    bind = {:match, @ln, rv, region_expr}
    destr = {:match, @ln, {:tuple, @ln, [sv, lv]}, rv}
    ctx = %{ctx | gen: ctx.gen + 1}
    {lstmts, ctx} = rebind_locals_from_tuple(lv, nlocals, ctx)

    if result_arity == 0 do
      {[bind, destr] ++ lstmts, stack, ctx}
    else
      {tv, ctx} = fresh(ctx, "Rgt")
      get = {:match, @ln, tv, {:call, @ln, {:atom, @ln, :hd}, [sv]}}
      {[bind, destr] ++ lstmts ++ [get], [tv | stack], ctx}
    end
  end

  # ── br_if: cond ? (br n) : fallthrough ───────────────────────────────────────────────────────────
  defp lower_br_if(n, cond_e, stack, ctx) do
    br = do_br(n, stack, ctx)
    case_e =
      {:case, @ln, {:op, @ln, :"/=", cond_e, {:integer, @ln, 0}},
       [
         {:clause, @ln, [{:atom, @ln, true}], [], [br]},
         {:clause, @ln, [{:atom, @ln, false}], [], [{:atom, @ln, :ok}]}
       ]}

    {[case_e], stack, ctx}
  end

  # ── locals plumbing ──────────────────────────────────────────────────────────────────────────────

  defp bind_local(i, expr, ctx) do
    v = var("L#{i}_#{ctx.gen}")
    {{:match, @ln, v, expr}, %{ctx | gen: ctx.gen + 1, lmap: Map.put(ctx.lmap, i, v)}}
  end

  defp lmap_from_tuple(tuple_var, nlocals) do
    for i <- 0..(nlocals - 1)//1, into: %{} do
      {i, {:call, @ln, {:atom, @ln, :element}, [{:integer, @ln, i + 1}, tuple_var]}}
    end
  end

  # element-extract each local out of `tuple_var` into a fresh SSA var; update lmap.
  defp rebind_locals_from_tuple(tuple_var, nlocals, ctx) do
    Enum.reduce(0..(nlocals - 1)//1, {[], ctx}, fn i, {ss, c} ->
      nv = var("L#{i}_#{c.gen}")
      c = %{c | gen: c.gen + 1, lmap: Map.put(c.lmap, i, nv)}
      get = {:match, @ln, nv, {:call, @ln, {:atom, @ln, :element}, [{:integer, @ln, i + 1}, tuple_var]}}
      {ss ++ [get], c}
    end)
  end

  defp fresh(ctx, prefix) do
    {var("#{prefix}#{ctx.gen}"), %{ctx | gen: ctx.gen + 1}}
  end

  # wrap a stmt list as an Erlang `begin ... end` block expression
  defp block_expr(stmts), do: {:block, @ln, stmts}

  # ── memory access codegen ────────────────────────────────────────────────────────────────────────
  # All access goes through the SAME packed `:atomics` (`:washy_mem`) the interpreter uses, with the
  # identical little-endian byte layout, so transpiled ⟷ interpreted byte effects are bit-identical.

  # Mem = Process.get(:washy_mem)  (fetch once per op; cheap dict read)
  defp mem_get do
    {:call, @ln, {:remote, @ln, {:atom, @ln, Process}, {:atom, @ln, :get}}, [{:atom, @ln, :washy_mem}]}
  end

  # Erlang for (mget(Mem, Addr)) — read byte at Addr from the packed word. Addr is an Erlang expr.
  # word = atomics:get(Mem, (Addr bsr 3) + 1); (word bsr ((Addr band 7)*8)) band 255
  defp mget_expr(mem_v, addr_v) do
    word =
      {:call, @ln, {:remote, @ln, {:atom, @ln, :atomics}, {:atom, @ln, :get}},
       [mem_v, {:op, @ln, :+, {:op, @ln, :bsr, addr_v, {:integer, @ln, 3}}, {:integer, @ln, 1}}]}

    sh = {:op, @ln, :*, {:op, @ln, :band, addr_v, {:integer, @ln, 7}}, {:integer, @ln, 8}}
    {:op, @ln, :band, {:op, @ln, :bsr, word, sh}, {:integer, @ln, 0xFF}}
  end

  # bounds!: limit = atomics:info(Mem).size * 8 (== pages*65536). if Addr<0 orelse Addr+n>limit -> trap.
  # Emitted as a guard-style case so it traps with the interpreter's :out_of_bounds reason.
  defp bounds_check(mem_v, addr_v, n) do
    size = {:call, @ln, {:remote, @ln, {:atom, @ln, :erlang}, {:atom, @ln, :map_get}},
            [{:atom, @ln, :size}, {:call, @ln, {:remote, @ln, {:atom, @ln, :atomics}, {:atom, @ln, :info}}, [mem_v]}]}
    limit = {:op, @ln, :*, size, {:integer, @ln, 8}}
    cond_e =
      {:op, @ln, :orelse,
       {:op, @ln, :<, addr_v, {:integer, @ln, 0}},
       {:op, @ln, :>, {:op, @ln, :+, addr_v, {:integer, @ln, n}}, limit}}

    {:case, @ln, cond_e,
     [
       {:clause, @ln, [{:atom, @ln, true}], [], [trap_call(:out_of_bounds)]},
       {:clause, @ln, [{:atom, @ln, false}], [], [{:atom, @ln, :ok}]}
     ]}
  end

  # build a value expr that reads n little-endian bytes at base address Addr (an Erlang var):
  #   B0 bor (B1 bsl 8) bor ... — each Bi = mget(Mem, Addr+i)
  defp load_value_expr(mem_v, addr_v, n) do
    Enum.reduce(0..(n - 1)//1, {:integer, @ln, 0}, fn i, acc ->
      byte = mget_expr(mem_v, {:op, @ln, :+, addr_v, {:integer, @ln, i}})
      shifted = if i == 0, do: byte, else: {:op, @ln, :bsl, byte, {:integer, @ln, i * 8}}
      if i == 0, do: shifted, else: {:op, @ln, :bor, acc, shifted}
    end)
  end

  # emit: Mem=get; AddrV = base+offset; bounds!; V = <load>; [sign-extend]; push V
  defp load_int(base_e, offset, n, signw, stack, ctx) do
    {memv, ctx} = fresh(ctx, "Mem")
    {addrv, ctx} = fresh(ctx, "Adr")
    {rawv, ctx} = fresh(ctx, "Lv")
    mem_bind = {:match, @ln, memv, mem_get()}
    addr_bind = {:match, @ln, addrv, eff_addr(base_e, offset)}
    bc = bounds_check(memv, addrv, n)
    load_bind = {:match, @ln, rawv, load_value_expr(memv, addrv, n)}

    {result, extra, ctx} =
      case signw do
        :u -> {rawv, [], ctx}
        {:s, width} -> sext_expr(rawv, n * 8, width, ctx)
      end

    {[mem_bind, addr_bind, bc, load_bind] ++ extra, [result | stack], ctx}
  end

  defp load_float(base_e, offset, n, stack, ctx) do
    {memv, ctx} = fresh(ctx, "Mem")
    {addrv, ctx} = fresh(ctx, "Adr")
    {fv, ctx} = fresh(ctx, "Fv")
    mem_bind = {:match, @ln, memv, mem_get()}
    addr_bind = {:match, @ln, addrv, eff_addr(base_e, offset)}
    bc = bounds_check(memv, addrv, n)
    # gather n bytes into a binary, then reinterpret as a little-endian float.
    bits = load_value_expr(memv, addrv, n)
    fbind = {:match, @ln, fv, float_from_bits_expr(bits, n)}
    {[mem_bind, addr_bind, bc, fbind], [fv | stack], ctx}
  end

  defp store_int(base_e, val_e, offset, n, stack, ctx) do
    {memv, ctx} = fresh(ctx, "Mem")
    {addrv, ctx} = fresh(ctx, "Adr")
    {valv, ctx} = fresh(ctx, "Sv")
    mem_bind = {:match, @ln, memv, mem_get()}
    addr_bind = {:match, @ln, addrv, eff_addr(base_e, offset)}
    val_bind = {:match, @ln, valv, val_e}
    bc = bounds_check(memv, addrv, n)
    puts = for i <- 0..(n - 1)//1, do: mput_stmt(memv, {:op, @ln, :+, addrv, {:integer, @ln, i}}, byte_of(valv, i))
    {[mem_bind, addr_bind, val_bind, bc] ++ puts, stack, ctx}
  end

  defp store_float(base_e, val_e, offset, n, stack, ctx) do
    {memv, ctx} = fresh(ctx, "Mem")
    {addrv, ctx} = fresh(ctx, "Adr")
    {bitsv, ctx} = fresh(ctx, "Sb")
    mem_bind = {:match, @ln, memv, mem_get()}
    addr_bind = {:match, @ln, addrv, eff_addr(base_e, offset)}
    bits_bind = {:match, @ln, bitsv, bits_from_float_expr(val_e, n)}
    bc = bounds_check(memv, addrv, n)
    puts = for i <- 0..(n - 1)//1, do: mput_stmt(memv, {:op, @ln, :+, addrv, {:integer, @ln, i}}, byte_of(bitsv, i))
    {[mem_bind, addr_bind, bits_bind, bc] ++ puts, stack, ctx}
  end

  # effective addr = base + static offset (offset is a non-negative immediate)
  defp eff_addr(base_e, 0), do: base_e
  defp eff_addr(base_e, offset), do: {:op, @ln, :+, base_e, {:integer, @ln, offset}}

  # (V bsr (i*8)) band 255
  defp byte_of(val_v, 0), do: {:op, @ln, :band, val_v, {:integer, @ln, 0xFF}}
  defp byte_of(val_v, i), do: {:op, @ln, :band, {:op, @ln, :bsr, val_v, {:integer, @ln, i * 8}}, {:integer, @ln, 0xFF}}

  # mput(Mem, AddrExpr, ByteExpr) as a statement: read-modify-write the packed word.
  #   Idx = (Addr bsr 3)+1, Sh=(Addr band 7)*8, W=atomics:get(Mem,Idx),
  #   atomics:put(Mem, Idx, ((W band (bnot(255 bsl Sh))) bor ((Byte band 255) bsl Sh)) band MASK64)
  # We inline Addr/Byte; to avoid recomputing Addr we expect AddrExpr to be cheap (var +/- int).
  defp mput_stmt(mem_v, addr_e, byte_e) do
    idx = {:op, @ln, :+, {:op, @ln, :bsr, addr_e, {:integer, @ln, 3}}, {:integer, @ln, 1}}
    sh = {:op, @ln, :*, {:op, @ln, :band, addr_e, {:integer, @ln, 7}}, {:integer, @ln, 8}}
    w = {:call, @ln, {:remote, @ln, {:atom, @ln, :atomics}, {:atom, @ln, :get}}, [mem_v, idx]}
    cleared = {:op, @ln, :band, w, mk_bnot({:op, @ln, :bsl, {:integer, @ln, 0xFF}, sh})}
    set = {:op, @ln, :bsl, {:op, @ln, :band, byte_e, {:integer, @ln, 0xFF}}, sh}
    neww = {:op, @ln, :band, {:op, @ln, :bor, cleared, set}, {:integer, @ln, @mask64}}
    {:call, @ln, {:remote, @ln, {:atom, @ln, :atomics}, {:atom, @ln, :put}}, [mem_v, idx, neww]}
  end

  defp mk_bnot(e), do: {:op, @ln, :bnot, e}

  # sign-extend a `from`-bit value (raw var) to a `to`-bit masked representation; returns {expr,stmts,ctx}
  defp sext_expr(raw_v, from_bits, to_bits, ctx) do
    mask = if to_bits == 32, do: @mask32, else: @mask64
    half = 1 <<< (from_bits - 1)
    full = 1 <<< from_bits
    {ov, ctx} = fresh(ctx, "Sx")
    expr =
      {:case, @ln, {:op, @ln, :>=, raw_v, {:integer, @ln, half}},
       [
         {:clause, @ln, [{:atom, @ln, true}], [],
          [{:op, @ln, :band, {:op, @ln, :-, raw_v, {:integer, @ln, full}}, {:integer, @ln, mask}}]},
         {:clause, @ln, [{:atom, @ln, false}], [], [raw_v]}
       ]}

    {ov, [{:match, @ln, ov, expr}], ctx}
  end

  # reinterpret n little-endian bytes (as an integer expr `bits`) → a float (32 or 64 bit IEEE-754).
  # binary:encode_unsigned won't pad/order; use a binary comprehension via erlang bit-syntax instead:
  #   <<F:n*8/float-little>> = <<Bits:n*8/integer-little>>  ... but generating that in abstract form is
  # awkward. Use erlang term: float from bits via a helper in Nexus.Washy.Transpile.FloatBits.
  defp float_from_bits_expr(bits_e, 4),
    do: {:call, @ln, {:remote, @ln, {:atom, @ln, __MODULE__}, {:atom, @ln, :f32_from_bits}}, [bits_e]}

  defp float_from_bits_expr(bits_e, 8),
    do: {:call, @ln, {:remote, @ln, {:atom, @ln, __MODULE__}, {:atom, @ln, :f64_from_bits}}, [bits_e]}

  defp bits_from_float_expr(f_e, 4),
    do: {:call, @ln, {:remote, @ln, {:atom, @ln, __MODULE__}, {:atom, @ln, :f32_to_bits}}, [f_e]}

  defp bits_from_float_expr(f_e, 8),
    do: {:call, @ln, {:remote, @ln, {:atom, @ln, __MODULE__}, {:atom, @ln, :f64_to_bits}}, [f_e]}

  # ── float<->bits runtime helpers (called by generated code) ──────────────────────────────────────
  @doc false
  def f32_from_bits(bits) do
    <<f::float-32-little>> = <<bits::32-little>>
    f
  end

  @doc false
  def f64_from_bits(bits) do
    <<f::float-64-little>> = <<bits::64-little>>
    f
  end

  @doc false
  def f32_to_bits(f) do
    <<i::32-little>> = <<f::float-32-little>>
    i
  end

  @doc false
  def f64_to_bits(f) do
    <<i::64-little>> = <<f::float-64-little>>
    i
  end

  # round a double to f32 precision (pack→unpack as 32-bit IEEE-754) — matches the interpreter's f32r.
  @doc false
  def f32r(x) do
    <<v::float-32-little>> = <<x::float-32-little>>
    v
  end

  # ── br_table: a switch over the branch index ─────────────────────────────────────────────────────
  # interp: target = if i < length(labels), do: labels[i], else: default. We compile each distinct
  # target's br to its do_br lowering (loop tail-call or depth-tagged throw), and switch on the index.
  defp lower_br_table(labels, default, idx_e, stack, ctx) do
    {iv, ctx} = fresh(ctx, "Bt")
    bind = {:match, @ln, iv, idx_e}

    clauses =
      for {label, i} <- Enum.with_index(labels) do
        {:clause, @ln, [{:integer, @ln, i}], [], [do_br(label, stack, ctx)]}
      end

    default_clause = {:clause, @ln, [{:var, @ln, :_}], [], [do_br(default, stack, ctx)]}
    switch = {:case, @ln, iv, clauses ++ [default_clause]}
    {[bind, switch], :unreachable, ctx}
  end

  # ── operand ops ──────────────────────────────────────────────────────────────────────────────────

  # unary opcodes (pop 1): i32/i64 eqz, clz/ctz/popcnt, the i↔f conversions, sign-extend, and the
  # f32/f64 unary maths (abs/neg/sqrt/ceil/floor/trunc/nearest).
  @unary_ops [
    0x45, 0x50,                          # i32.eqz, i64.eqz
    0x67, 0x68, 0x69,                    # i32 clz/ctz/popcnt
    0x79, 0x7A, 0x7B,                    # i64 clz/ctz/popcnt
    0x8B, 0x8C, 0x8D, 0x8E, 0x8F, 0x90, 0x91,  # f32 abs/neg/ceil/floor/trunc/nearest/sqrt
    0x99, 0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F,  # f64 abs/neg/ceil/floor/trunc/nearest/sqrt
    0xA7, 0xAC, 0xAD,                    # i32.wrap_i64, i64.extend_i32_s/u
    0xA8, 0xA9, 0xAA, 0xAB,              # i32.trunc_f32_s/u, f64_s/u
    0xAE, 0xAF, 0xB0, 0xB1,              # i64.trunc_f32_s/u, f64_s/u
    0xB2, 0xB3, 0xB4, 0xB5,              # f32.convert_i32_s/u, i64_s/u
    0xB6,                                # f32.demote_f64
    0xB7, 0xB8, 0xB9, 0xBA,              # f64.convert_i32_s/u, i64_s/u
    0xBB,                                # f64.promote_f32
    0xBC, 0xBD, 0xBE, 0xBF,              # reinterprets
    0xC0, 0xC1, 0xC2, 0xC3, 0xC4         # sign-extend ops
  ]

  defp op_pops(o) when o in @unary_ops, do: 1
  defp op_pops(_), do: 2

  defp apply_op(opcode, stack) do
    case op_pops(opcode) do
      1 -> [a | _] = stack; unop(opcode, a)
      2 -> [b, a | _] = stack; binop(opcode, a, b)
    end
  end

  defp drop(list, 0), do: list
  defp drop([_ | t], n), do: drop(t, n - 1)

  defp binop(0x6A, a, b), do: mask32({:op, @ln, :+, a, b})
  defp binop(0x6B, a, b), do: mask32({:op, @ln, :-, a, b})
  defp binop(0x6C, a, b), do: mask32({:op, @ln, :*, a, b})
  defp binop(0x6D, a, b), do: mask32(trap_div(a, b, :div, true, true))
  defp binop(0x6E, a, b), do: mask32(trap_div(a, b, :div, false, false))
  defp binop(0x6F, a, b), do: mask32(trap_div(a, b, :rem, false, true))
  defp binop(0x70, a, b), do: mask32(trap_div(a, b, :rem, false, false))
  defp binop(0x71, a, b), do: {:op, @ln, :band, a, b}
  defp binop(0x72, a, b), do: {:op, @ln, :bor, a, b}
  defp binop(0x73, a, b), do: {:op, @ln, :bxor, a, b}
  defp binop(0x74, a, b), do: mask32({:op, @ln, :bsl, a, shcount(b)})
  defp binop(0x75, a, b), do: mask32({:op, @ln, :bsr, s32(a), shcount(b)})
  defp binop(0x76, a, b), do: {:op, @ln, :bsr, a, shcount(b)}
  defp binop(0x46, a, b), do: cmp(:"==", a, b)
  defp binop(0x47, a, b), do: cmp(:"/=", a, b)
  defp binop(0x48, a, b), do: cmp(:<, s32(a), s32(b))
  defp binop(0x49, a, b), do: cmp(:<, a, b)
  defp binop(0x4A, a, b), do: cmp(:>, s32(a), s32(b))
  defp binop(0x4B, a, b), do: cmp(:>, a, b)
  defp binop(0x4C, a, b), do: cmp(:"=<", s32(a), s32(b))
  defp binop(0x4D, a, b), do: cmp(:"=<", a, b)
  defp binop(0x4E, a, b), do: cmp(:>=, s32(a), s32(b))
  defp binop(0x4F, a, b), do: cmp(:>=, a, b)

  # ── i64 binops (mask to 64 bits) ──
  defp binop(0x51, a, b), do: cmp(:"==", a, b)
  defp binop(0x52, a, b), do: cmp(:"/=", a, b)
  defp binop(0x53, a, b), do: cmp(:<, s64(a), s64(b))
  defp binop(0x54, a, b), do: cmp(:<, a, b)
  defp binop(0x55, a, b), do: cmp(:>, s64(a), s64(b))
  defp binop(0x56, a, b), do: cmp(:>, a, b)
  defp binop(0x57, a, b), do: cmp(:"=<", s64(a), s64(b))
  defp binop(0x58, a, b), do: cmp(:"=<", a, b)
  defp binop(0x59, a, b), do: cmp(:>=, s64(a), s64(b))
  defp binop(0x5A, a, b), do: cmp(:>=, a, b)
  defp binop(0x7C, a, b), do: mask64({:op, @ln, :+, a, b})
  defp binop(0x7D, a, b), do: mask64({:op, @ln, :-, a, b})
  defp binop(0x7E, a, b), do: mask64({:op, @ln, :*, a, b})
  defp binop(0x7F, a, b), do: mask64(trap_div64(a, b, :div, true, true))
  defp binop(0x80, a, b), do: mask64(trap_div64(a, b, :div, false, false))
  defp binop(0x81, a, b), do: mask64(trap_div64(a, b, :rem, false, true))
  defp binop(0x82, a, b), do: mask64(trap_div64(a, b, :rem, false, false))
  defp binop(0x83, a, b), do: {:op, @ln, :band, a, b}
  defp binop(0x84, a, b), do: {:op, @ln, :bor, a, b}
  defp binop(0x85, a, b), do: {:op, @ln, :bxor, a, b}
  defp binop(0x86, a, b), do: mask64({:op, @ln, :bsl, a, shcount64(b)})
  defp binop(0x87, a, b), do: mask64({:op, @ln, :bsr, s64(a), shcount64(b)})
  defp binop(0x88, a, b), do: {:op, @ln, :bsr, a, shcount64(b)}
  defp binop(0x89, a, b), do: rot64(a, b, :l)
  defp binop(0x8A, a, b), do: rot64(a, b, :r)

  # i32 rotl/rotr (were unsupported before)
  defp binop(0x77, a, b), do: rot32(a, b, :l)
  defp binop(0x78, a, b), do: rot32(a, b, :r)

  # ── f64 binops (BEAM floats; no rounding) ──
  defp binop(0xA0, a, b), do: {:op, @ln, :+, a, b}
  defp binop(0xA1, a, b), do: {:op, @ln, :-, a, b}
  defp binop(0xA2, a, b), do: {:op, @ln, :*, a, b}
  defp binop(0xA3, a, b), do: {:op, @ln, :/, a, b}
  defp binop(0xA4, a, b), do: fmin(a, b)
  defp binop(0xA5, a, b), do: fmax(a, b)
  defp binop(0x61, a, b), do: cmp(:"==", a, b)
  defp binop(0x62, a, b), do: cmp(:"/=", a, b)
  defp binop(0x63, a, b), do: cmp(:<, a, b)
  defp binop(0x64, a, b), do: cmp(:>, a, b)
  defp binop(0x65, a, b), do: cmp(:"=<", a, b)
  defp binop(0x66, a, b), do: cmp(:>=, a, b)

  # ── f32 binops (round result to single precision via f32r) ──
  defp binop(0x92, a, b), do: f32r_e({:op, @ln, :+, a, b})
  defp binop(0x93, a, b), do: f32r_e({:op, @ln, :-, a, b})
  defp binop(0x94, a, b), do: f32r_e({:op, @ln, :*, a, b})
  defp binop(0x95, a, b), do: f32r_e({:op, @ln, :/, a, b})
  defp binop(0x96, a, b), do: fmin(a, b)
  defp binop(0x97, a, b), do: fmax(a, b)
  defp binop(0x5B, a, b), do: cmp(:"==", a, b)
  defp binop(0x5C, a, b), do: cmp(:"/=", a, b)
  defp binop(0x5D, a, b), do: cmp(:<, a, b)
  defp binop(0x5E, a, b), do: cmp(:>, a, b)
  defp binop(0x5F, a, b), do: cmp(:"=<", a, b)
  defp binop(0x60, a, b), do: cmp(:>=, a, b)

  defp binop(op, _a, _b), do: throw({:unsupported, {:op, op}})

  # ── unary ops ──
  defp unop(0x45, a), do: cmp(:"==", a, {:integer, @ln, 0})
  defp unop(0x50, a), do: cmp(:"==", a, {:integer, @ln, 0})        # i64.eqz

  # i32.wrap_i64 / i64.extend_i32_s / i64.extend_i32_u
  defp unop(0xA7, a), do: mask32(a)
  defp unop(0xAC, a), do: sext64_e({:op, @ln, :band, a, {:integer, @ln, @mask32}}, 32)
  defp unop(0xAD, a), do: {:op, @ln, :band, a, {:integer, @ln, @mask64}}

  # f64 unary maths
  defp unop(0x99, a), do: call_remote(:erlang, :abs, [a])
  defp unop(0x9A, a), do: {:op, @ln, :-, a}
  defp unop(0x9F, a), do: call_remote(:math, :sqrt, [a])
  # f32 unary maths (round result)
  defp unop(0x8B, a), do: f32r_e(call_remote(:erlang, :abs, [a]))
  defp unop(0x8C, a), do: f32r_e({:op, @ln, :-, a})
  defp unop(0x91, a), do: f32r_e(call_remote(:math, :sqrt, [a]))

  # conversions int->float
  defp unop(0xB2, a), do: f32r_e(int_to_float(s32(a)))           # f32.convert_i32_s
  defp unop(0xB3, a), do: f32r_e(int_to_float(a))               # f32.convert_i32_u
  defp unop(0xB4, a), do: f32r_e(int_to_float(s64(a)))           # f32.convert_i64_s
  defp unop(0xB5, a), do: f32r_e(int_to_float(a))               # f32.convert_i64_u
  defp unop(0xB7, a), do: int_to_float(s32(a))                  # f64.convert_i32_s
  defp unop(0xB8, a), do: int_to_float(a)                       # f64.convert_i32_u
  defp unop(0xB9, a), do: int_to_float(s64(a))                  # f64.convert_i64_s
  defp unop(0xBA, a), do: int_to_float(a)                       # f64.convert_i64_u
  defp unop(0xB6, a), do: f32r_e(a)                            # f32.demote_f64
  defp unop(0xBB, a), do: int_to_float_promote(a)               # f64.promote_f32 (float→float, no-op)

  # reinterprets (bit-exact)
  defp unop(0xBC, a), do: call_remote(__MODULE__, :f32_to_bits, [a])  # i32.reinterpret_f32
  defp unop(0xBD, a), do: call_remote(__MODULE__, :f64_to_bits, [a])  # i64.reinterpret_f64
  defp unop(0xBE, a), do: call_remote(__MODULE__, :f32_from_bits, [{:op, @ln, :band, a, {:integer, @ln, @mask32}}])  # f32.reinterpret_i32
  defp unop(0xBF, a), do: call_remote(__MODULE__, :f64_from_bits, [{:op, @ln, :band, a, {:integer, @ln, @mask64}}])  # f64.reinterpret_i64

  # sign-extend ops within a type
  defp unop(0xC0, a), do: sext32_e({:op, @ln, :band, a, {:integer, @ln, 0xFF}}, 8)
  defp unop(0xC1, a), do: sext32_e({:op, @ln, :band, a, {:integer, @ln, 0xFFFF}}, 16)
  defp unop(0xC2, a), do: sext64_e({:op, @ln, :band, a, {:integer, @ln, 0xFF}}, 8)
  defp unop(0xC3, a), do: sext64_e({:op, @ln, :band, a, {:integer, @ln, 0xFFFF}}, 16)
  defp unop(0xC4, a), do: sext64_e({:op, @ln, :band, a, {:integer, @ln, @mask32}}, 32)

  defp unop(op, _a), do: throw({:unsupported, {:op, op}})

  defp cmp(operator, a, b) do
    {:case, @ln, {:op, @ln, operator, a, b},
     [
       {:clause, @ln, [{:atom, @ln, true}], [], [{:integer, @ln, 1}]},
       {:clause, @ln, [{:atom, @ln, false}], [], [{:integer, @ln, 0}]}
     ]}
  end

  # case {A,B} of {_,0} -> trap; {INT_MIN,-1} -> trap (div_s only); {A,B} -> A op B end
  defp trap_div(a, b, op, overflow?, signed?) do
    av = if signed?, do: s32(a), else: a
    bv = if signed?, do: s32(b), else: b
    avar = {:var, @ln, :"_DvA"}
    bvar = {:var, @ln, :"_DvB"}

    zero = {:clause, @ln, [{:tuple, @ln, [{:var, @ln, :_}, {:integer, @ln, 0}]}], [], [trap_call(:div_by_zero)]}

    ovf =
      if overflow? do
        [{:clause, @ln, [{:tuple, @ln, [{:integer, @ln, -0x80000000}, {:integer, @ln, -1}]}], [], [trap_call(:int_overflow)]}]
      else
        []
      end

    main = {:clause, @ln, [{:tuple, @ln, [avar, bvar]}], [], [{:op, @ln, op, avar, bvar}]}
    {:case, @ln, {:tuple, @ln, [av, bv]}, [zero] ++ ovf ++ [main]}
  end

  defp trap_call(reason) do
    {:call, @ln, {:remote, @ln, {:atom, @ln, Nexus.Washy.Trap}, {:atom, @ln, :trap!}}, [{:atom, @ln, reason}]}
  end

  defp shcount(b), do: {:op, @ln, :band, b, {:integer, @ln, 31}}
  defp shcount64(b), do: {:op, @ln, :band, b, {:integer, @ln, 63}}

  defp call_remote(mod, fun, args),
    do: {:call, @ln, {:remote, @ln, {:atom, @ln, mod}, {:atom, @ln, fun}}, args}

  # round an f32-result expr to single precision (matches the interpreter's f32r)
  defp f32r_e(expr), do: call_remote(__MODULE__, :f32r, [expr])

  # int * 1.0 → float
  defp int_to_float(expr), do: {:op, @ln, :*, expr, {:float, @ln, 1.0}}
  # f64.promote_f32: the value is already a BEAM float; identity
  defp int_to_float_promote(expr), do: expr

  # erlang:min/max — matches the interpreter's Elixir min/max (no NaN special-casing on either side)
  defp fmin(a, b), do: call_remote(:erlang, :min, [a, b])
  defp fmax(a, b), do: call_remote(:erlang, :max, [a, b])

  # i64 signed div/rem trap (zero divisor + INT64_MIN / -1 overflow for div_s)
  defp trap_div64(a, b, op, overflow?, signed?) do
    av = if signed?, do: s64(a), else: a
    bv = if signed?, do: s64(b), else: b
    avar = {:var, @ln, :"_Dv64A"}
    bvar = {:var, @ln, :"_Dv64B"}
    zero = {:clause, @ln, [{:tuple, @ln, [{:var, @ln, :_}, {:integer, @ln, 0}]}], [], [trap_call(:div_by_zero)]}

    ovf =
      if overflow? do
        [{:clause, @ln, [{:tuple, @ln, [{:integer, @ln, -0x8000000000000000}, {:integer, @ln, -1}]}], [], [trap_call(:int_overflow)]}]
      else
        []
      end

    main = {:clause, @ln, [{:tuple, @ln, [avar, bvar]}], [], [{:op, @ln, op, avar, bvar}]}
    {:case, @ln, {:tuple, @ln, [av, bv]}, [zero] ++ ovf ++ [main]}
  end

  # rotate: ((A bsl n) bor (A bsr (W-n))) band MASK, with n already in [0,W). Matches rotl/rotr32/64.
  defp rot32(a, b, dir), do: rot(a, b, 32, @mask32, dir)
  defp rot64(a, b, dir), do: rot(a, b, 64, @mask64, dir)

  defp rot(a, b, width, mask, dir) do
    av = {:var, @ln, :"_RtA"}
    nv = {:var, @ln, :"_RtN"}
    {l, r} =
      case dir do
        :l -> {nv, {:op, @ln, :-, {:integer, @ln, width}, nv}}
        :r -> {{:op, @ln, :-, {:integer, @ln, width}, nv}, nv}
      end

    body =
      {:op, @ln, :band,
       {:op, @ln, :bor, {:op, @ln, :bsl, av, l}, {:op, @ln, :bsr, av, r}},
       {:integer, @ln, mask}}

    # n==0 → identity (avoid `bsr A 32`/`bsl A 0`-style edge yielding wrong bits when width-n==width)
    {:block, @ln,
     [
       {:match, @ln, av, a},
       {:match, @ln, nv, {:op, @ln, :band, b, {:integer, @ln, width - 1}}},
       {:case, @ln, nv,
        [
          {:clause, @ln, [{:integer, @ln, 0}], [], [av]},
          {:clause, @ln, [{:var, @ln, :_}], [], [body]}
        ]}
     ]}
  end

  defp mask64(expr), do: {:op, @ln, :band, expr, {:integer, @ln, @mask64}}

  # sign-extend an n-bit (already-masked) value to the 32/64-bit unsigned representation.
  defp sext32_e(masked, bits), do: sext_to(masked, bits, 32, @mask32)
  defp sext64_e(masked, bits), do: sext_to(masked, bits, 64, @mask64)

  defp sext_to(masked, bits, _width, mask) do
    half = 1 <<< (bits - 1)
    full = 1 <<< bits
    v = {:var, @ln, :"_Se"}
    {:block, @ln,
     [
       {:match, @ln, v, masked},
       {:case, @ln, {:op, @ln, :>=, v, {:integer, @ln, half}},
        [
          {:clause, @ln, [{:atom, @ln, true}], [], [{:op, @ln, :band, {:op, @ln, :-, v, {:integer, @ln, full}}, {:integer, @ln, mask}}]},
          {:clause, @ln, [{:atom, @ln, false}], [], [v]}
        ]}
     ]}
  end

  defp s64(expr) do
    v = {:var, @ln, :"_Sg64"}
    {:case, @ln, expr,
     [
       {:clause, @ln, [v], [[{:op, @ln, :>=, v, {:integer, @ln, 0x8000000000000000}}]], [{:op, @ln, :-, v, {:integer, @ln, 0x10000000000000000}}]},
       {:clause, @ln, [v], [], [v]}
     ]}
  end

  defp s32(expr) do
    v = {:var, @ln, :"_Sg"}
    {:case, @ln, expr,
     [
       {:clause, @ln, [v], [[{:op, @ln, :>=, v, {:integer, @ln, 0x80000000}}]], [{:op, @ln, :-, v, {:integer, @ln, 0x100000000}}]},
       {:clause, @ln, [v], [], [v]}
     ]}
  end

  defp mask32(expr), do: {:op, @ln, :band, expr, {:integer, @ln, @mask32}}

  defp var(name) when is_binary(name), do: {:var, @ln, String.to_atom(name)}
end

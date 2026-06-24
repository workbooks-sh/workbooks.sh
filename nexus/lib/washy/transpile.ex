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
        apply(mname, fname, args)
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
    ret = case stack do
      [top | _] -> top
      [] -> {:integer, @ln, 0}
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

  # ── operand ops ──────────────────────────────────────────────────────────────────────────────────

  defp op_pops(0x45), do: 1
  defp op_pops(o) when o in 0x67..0x69, do: 1
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
  defp binop(op, _a, _b), do: throw({:unsupported, {:op, op}})

  defp unop(0x45, a), do: cmp(:"==", a, {:integer, @ln, 0})
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

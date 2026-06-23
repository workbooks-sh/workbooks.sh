defmodule Nexus.Washy do
  @moduledoc """
  **Washy** — a WebAssembly interpreter in PURE ELIXIR. Untrusted wasm executes *as BEAM code*, so the
  isolation IS the BEAM's: run a module inside a process and you get its own heap (memory isolation), a
  trap = a caught exception (crash isolation), reduction-counting (preemptive fairness), and OTP
  supervision — none of it bolted on. No native runtime means no SFI-escape leakage class (a NIF fault
  crashes the whole VM; a Washy fault kills one process). Host imports are plain Elixir function calls.

  This is the spike foundation: a decoder (magic/version/sections, LEB128) + a stack-machine interpreter.
  Milestone 1 = integer arithmetic + function calls, proving pure-BEAM wasm execution. Opcodes, linear
  memory (`:atomics`), control flow, and WASI host imports build out from here toward running the shell.

      {:ok, mod} = Nexus.Washy.decode(wasm_binary)
      7 = Nexus.Washy.call(mod, "add", [3, 4])
  """
  import Bitwise

  defstruct types: [], funcs: [], exports: %{}, code: [], mem: nil, imports: [], globals: [], data: [], elements: []

  @typedoc "A decoded module."
  @type t :: %__MODULE__{}

  @mask32 0xFFFFFFFF
  @mask64 0xFFFFFFFFFFFFFFFF

  # ── decode ────────────────────────────────────────────────────────────────────────────────────

  @doc "Decode a `.wasm` binary into a module struct."
  def decode(<<0x00, 0x61, 0x73, 0x6D, 1, 0, 0, 0, rest::binary>>) do
    {:ok, decode_sections(rest, %__MODULE__{})}
  rescue
    e -> {:error, {:decode, Exception.message(e)}}
  end

  def decode(_), do: {:error, :not_a_wasm_module}

  defp decode_sections(<<>>, mod), do: mod

  defp decode_sections(<<id, rest::binary>>, mod) do
    {size, rest} = uleb(rest)
    <<content::binary-size(size), rest2::binary>> = rest
    decode_sections(rest2, section(id, content, mod))
  end

  # 1 = type: vec of func types `0x60 vec(valtype) vec(valtype)`
  defp section(1, content, mod) do
    {types, _} = vec(content, &functype/1)
    %{mod | types: types}
  end

  # 3 = function: vec of type indices (one per local function)
  defp section(3, content, mod) do
    {idxs, _} = vec(content, &uleb/1)
    %{mod | funcs: idxs}
  end

  # 7 = export: vec of (name, kind, index); keep the func exports as name => func index
  defp section(7, content, mod) do
    {exports, _} = vec(content, &export/1)
    %{mod | exports: exports |> Enum.filter(&match?({_, :func, _}, &1)) |> Map.new(fn {n, :func, i} -> {n, i} end)}
  end

  # 10 = code: vec of (size, vec(locals), body-bytes-ending-in-0x0B)
  defp section(10, content, mod) do
    {code, _} = vec(content, &code_entry/1)
    %{mod | code: code}
  end

  # 2 = import: vec of (module, field, desc). FUNC imports occupy the LOW function indices (before local
  # funcs), so we keep them in order; non-func imports are skipped for now.
  defp section(2, content, mod) do
    {imports, _} = vec(content, &import_entry/1)
    funcs = imports |> Enum.filter(&match?({_, _, :func, _}, &1)) |> Enum.map(fn {m, n, :func, t} -> {m, n, t} end)
    %{mod | imports: funcs}
  end

  # 5 = memory: vec of limits (wasm MVP has one memory). limit = flag(0|1) then min[, max] in 64KB pages.
  defp section(5, content, mod) do
    {mems, _} = vec(content, &limits/1)
    %{mod | mem: List.first(mems)}
  end

  # 6 = global: vec of (valtype, mut, init-const-expr). Store the parsed init instrs; evaluated at start.
  defp section(6, content, mod) do
    {globals, _} = vec(content, &global_entry/1)
    %{mod | globals: globals}
  end

  # 9 = element: vec of segments that initialize the function TABLE (for call_indirect / function ptrs).
  defp section(9, content, mod) do
    {elements, _} = vec(content, &element_entry/1)
    %{mod | elements: elements}
  end

  # 11 = data: vec of segments that initialize memory with constant bytes (string literals etc.).
  defp section(11, content, mod) do
    {data, _} = vec(content, &data_entry/1)
    %{mod | data: data}
  end

  # element flag 0 = active table 0: (offset-const-expr, vec funcidx). (Other flag variants: minimal handling.)
  defp element_entry(<<0, rest::binary>>) do
    {offset, :end, rest} = parse_instrs(rest)
    {funcs, rest} = vec(rest, &uleb/1)
    {{offset, funcs}, rest}
  end

  # sections we don't need yet (table/element/custom/…) are skipped
  defp section(_id, _content, mod), do: mod

  defp data_entry(<<0, rest::binary>>) do
    {offset, :end, rest} = parse_instrs(rest)
    {n, rest} = uleb(rest)
    <<bytes::binary-size(n), rest::binary>> = rest
    {{:active, offset, bytes}, rest}
  end

  defp data_entry(<<1, rest::binary>>) do
    {n, rest} = uleb(rest)
    <<bytes::binary-size(n), rest::binary>> = rest
    {{:passive, bytes}, rest}
  end

  defp data_entry(<<2, rest::binary>>) do
    {_memidx, rest} = uleb(rest)
    {offset, :end, rest} = parse_instrs(rest)
    {n, rest} = uleb(rest)
    <<bytes::binary-size(n), rest::binary>> = rest
    {{:active, offset, bytes}, rest}
  end

  defp global_entry(<<_valtype, _mut, rest::binary>>) do
    {init, :end, rest} = parse_instrs(rest)
    {init, rest}
  end

  defp import_entry(content) do
    {mod_name, rest} = name(content)
    {field, rest} = name(rest)
    <<kind, rest::binary>> = rest
    case kind do
      0 -> {tidx, rest} = uleb(rest); {{mod_name, field, :func, tidx}, rest}
      2 -> {_lim, rest} = limits(rest); {{mod_name, field, :mem, nil}, rest}
      3 -> <<_vt, _mut, rest::binary>> = rest; {{mod_name, field, :global, nil}, rest}
      1 -> <<_rt, rest::binary>> = rest; {_lim, rest} = limits(rest); {{mod_name, field, :table, nil}, rest}
    end
  end

  defp limits(<<0, rest::binary>>), do: ({min, rest} = uleb(rest)) && {{min, nil}, rest}
  defp limits(<<1, rest::binary>>) do
    {min, rest} = uleb(rest)
    {max, rest} = uleb(rest)
    {{min, max}, rest}
  end

  defp functype(<<0x60, rest::binary>>) do
    {params, rest} = vec(rest, &valtype/1)
    {results, rest} = vec(rest, &valtype/1)
    {{params, results}, rest}
  end

  defp valtype(<<t, rest::binary>>), do: {t, rest}

  defp export(content) do
    {name, rest} = name(content)
    <<kind, rest::binary>> = rest
    {idx, rest} = uleb(rest)
    kind = %{0 => :func, 1 => :table, 2 => :mem, 3 => :global}[kind] || kind
    {{name, kind, idx}, rest}
  end

  defp code_entry(content) do
    {size, rest} = uleb(content)
    <<body::binary-size(size), rest2::binary>> = rest
    {locals, code} = vec(body, fn b -> {n, b} = uleb(b); {t, b} = valtype(b); {{n, t}, b} end)
    nlocals = Enum.reduce(locals, 0, fn {n, _}, acc -> acc + n end)
    {instrs, :end, _} = parse_instrs(code)
    {{nlocals, instrs}, rest2}
  end

  # ── parse a function body's bytes into a STRUCTURED instruction list ─────────────────────────────
  # Reads until the matching `end` (0x0B) / `else` (0x05); block/loop/if recurse so each carries its own
  # inner instruction list. This is what makes structured control flow (br targets) tractable.
  defp parse_instrs(bin, acc \\ [])
  defp parse_instrs(<<0x0B, rest::binary>>, acc), do: {Enum.reverse(acc), :end, rest}
  defp parse_instrs(<<0x05, rest::binary>>, acc), do: {Enum.reverse(acc), :else, rest}

  defp parse_instrs(<<op, rest::binary>>, acc) do
    {instr, rest} = parse_op(op, rest)
    parse_instrs(rest, [instr | acc])
  end

  defp parse_op(0x02, rest), do: ({_bt, r} = blocktype(rest); {body, :end, r} = parse_instrs(r); {{:block, body}, r})
  defp parse_op(0x03, rest), do: ({_bt, r} = blocktype(rest); {body, :end, r} = parse_instrs(r); {{:loop, body}, r})

  defp parse_op(0x04, rest) do
    {_bt, r} = blocktype(rest)
    {then_b, term, r} = parse_instrs(r)
    {else_b, r} = if term == :else, do: (fn -> {e, :end, r2} = parse_instrs(r); {e, r2} end).(), else: {[], r}
    {{:if, then_b, else_b}, r}
  end

  defp parse_op(0x23, rest), do: ({i, r} = uleb(rest); {{:global_get, i}, r})
  defp parse_op(0x24, rest), do: ({i, r} = uleb(rest); {{:global_set, i}, r})
  defp parse_op(0x41, rest), do: ({v, r} = sleb(rest); {{:i32_const, v}, r})
  defp parse_op(0x42, rest), do: ({v, r} = sleb(rest); {{:i64_const, v &&& @mask64}, r})
  # i64 loads/stores (the load width + sign is encoded in the op; value masked to 64 bits)
  defp parse_op(0x29, rest), do: ({o, r} = memarg(rest); {{:i64_load, o, 8, false}, r})
  defp parse_op(0x30, rest), do: ({o, r} = memarg(rest); {{:i64_load, o, 1, true}, r})
  defp parse_op(0x31, rest), do: ({o, r} = memarg(rest); {{:i64_load, o, 1, false}, r})
  defp parse_op(0x32, rest), do: ({o, r} = memarg(rest); {{:i64_load, o, 2, true}, r})
  defp parse_op(0x33, rest), do: ({o, r} = memarg(rest); {{:i64_load, o, 2, false}, r})
  defp parse_op(0x34, rest), do: ({o, r} = memarg(rest); {{:i64_load, o, 4, true}, r})
  defp parse_op(0x35, rest), do: ({o, r} = memarg(rest); {{:i64_load, o, 4, false}, r})
  defp parse_op(0x37, rest), do: ({o, r} = memarg(rest); {{:i64_store, o, 8}, r})
  defp parse_op(0x3C, rest), do: ({o, r} = memarg(rest); {{:i64_store, o, 1}, r})
  defp parse_op(0x3D, rest), do: ({o, r} = memarg(rest); {{:i64_store, o, 2}, r})
  defp parse_op(0x3E, rest), do: ({o, r} = memarg(rest); {{:i64_store, o, 4}, r})
  defp parse_op(0x20, rest), do: ({i, r} = uleb(rest); {{:local_get, i}, r})
  defp parse_op(0x21, rest), do: ({i, r} = uleb(rest); {{:local_set, i}, r})
  defp parse_op(0x22, rest), do: ({i, r} = uleb(rest); {{:local_tee, i}, r})
  defp parse_op(0x10, rest), do: ({f, r} = uleb(rest); {{:call, f}, r})
  defp parse_op(0x11, rest), do: ({tidx, r} = uleb(rest); {_tbl, r} = uleb(r); {{:call_indirect, tidx}, r})
  defp parse_op(0x0C, rest), do: ({n, r} = uleb(rest); {{:br, n}, r})
  defp parse_op(0x0D, rest), do: ({n, r} = uleb(rest); {{:br_if, n}, r})
  defp parse_op(0x0F, rest), do: {{:return}, rest}
  defp parse_op(0x1A, rest), do: {{:drop}, rest}
  defp parse_op(0x00, rest), do: {{:unreachable}, rest}
  defp parse_op(0x01, rest), do: {{:nop}, rest}
  defp parse_op(0x28, rest), do: ({o, r} = memarg(rest); {{:i32_load, o}, r})
  defp parse_op(0x2C, rest), do: ({o, r} = memarg(rest); {{:i32_load8s, o}, r})
  defp parse_op(0x2D, rest), do: ({o, r} = memarg(rest); {{:i32_load8u, o}, r})
  defp parse_op(0x2E, rest), do: ({o, r} = memarg(rest); {{:i32_load16s, o}, r})
  defp parse_op(0x2F, rest), do: ({o, r} = memarg(rest); {{:i32_load16u, o}, r})
  defp parse_op(0x36, rest), do: ({o, r} = memarg(rest); {{:i32_store, o}, r})
  defp parse_op(0x3A, rest), do: ({o, r} = memarg(rest); {{:i32_store8, o}, r})
  defp parse_op(0x3B, rest), do: ({o, r} = memarg(rest); {{:i32_store16, o}, r})
  defp parse_op(0x3F, <<_, rest::binary>>), do: {{:memory_size}, rest}
  defp parse_op(0x40, <<_, rest::binary>>), do: {{:memory_grow}, rest}
  # floats: const literals (raw IEEE-754) + loads/stores
  defp parse_op(0x43, <<v::float-32-little, rest::binary>>), do: {{:fconst, v}, rest}
  defp parse_op(0x44, <<v::float-64-little, rest::binary>>), do: {{:fconst, v}, rest}
  defp parse_op(0x2A, rest), do: ({o, r} = memarg(rest); {{:f32_load, o}, r})
  defp parse_op(0x2B, rest), do: ({o, r} = memarg(rest); {{:f64_load, o}, r})
  defp parse_op(0x38, rest), do: ({o, r} = memarg(rest); {{:f32_store, o}, r})
  defp parse_op(0x39, rest), do: ({o, r} = memarg(rest); {{:f64_store, o}, r})
  # everything else (arithmetic + comparisons, no immediate) is a pure stack op, dispatched by opcode
  defp parse_op(op, rest), do: {{:op, op}, rest}

  # blocktype is one byte for the common cases (0x40 empty / a valtype); we don't need its value to run.
  defp blocktype(<<_b, rest::binary>>), do: {nil, rest}

  defp name(content) do
    {len, rest} = uleb(content)
    <<s::binary-size(len), rest2::binary>> = rest
    {s, rest2}
  end

  # vec = uleb count, then `count` items parsed by `f`
  defp vec(bin, f) do
    {count, rest} = uleb(bin)
    Enum.reduce(1..count//1, {[], rest}, fn _, {acc, b} -> {x, b} = f.(b); {[x | acc], b} end)
    |> then(fn {acc, b} -> {Enum.reverse(acc), b} end)
  end

  # LEB128 unsigned + signed
  defp uleb(bin), do: uleb(bin, 0, 0)
  defp uleb(<<byte, rest::binary>>, shift, acc) do
    acc = acc ||| ((byte &&& 0x7F) <<< shift)
    if (byte &&& 0x80) != 0, do: uleb(rest, shift + 7, acc), else: {acc, rest}
  end

  defp sleb(bin), do: sleb(bin, 0, 0)
  defp sleb(<<byte, rest::binary>>, shift, acc) do
    acc = acc ||| ((byte &&& 0x7F) <<< shift)
    shift2 = shift + 7
    if (byte &&& 0x80) != 0 do
      sleb(rest, shift2, acc)
    else
      acc = if (byte &&& 0x40) != 0 and shift2 < 64, do: acc ||| (-1 <<< shift2), else: acc
      {acc, rest}
    end
  end

  # ── run ───────────────────────────────────────────────────────────────────────────────────────

  @doc """
  Call an exported function by name with integer args. Returns the top-of-stack result (or nil). Builds a
  fresh runtime: a per-call **linear memory** as an `:atomics` array (mutable, NIF-free, BEAM-native — the
  primitive that lets wasm's mutable byte memory live inside an isolated BEAM process).
  """
  def call(%__MODULE__{} = mod, name, args) when is_list(args) do
    {result, _io} = call_io(mod, name, args)
    result
  end

  @doc "Like `call/3`, but also returns captured stdout (what the guest wrote via WASI `fd_write`)."
  def call_io(%__MODULE__{} = mod, name, args) when is_list(args) do
    prev = Process.get(:washy_out)
    Process.put(:washy_out, [])
    globals = new_globals(mod.globals)
    mem = new_mem(mod.mem)
    init_data(mem, globals, mod.data)
    rt = %{mod: mod, mem: mem, globals: globals, table: new_table(mod.elements, globals)}
    result = call_fn(rt, Map.fetch!(mod.exports, name), args)
    out = Process.get(:washy_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
    if prev == nil, do: Process.delete(:washy_out), else: Process.put(:washy_out, prev)
    {result, out}
  end

  # one `:atomics` slot per byte (simple + correct; pack-to-words is a later optimization). nil = no memory.
  defp new_mem(nil), do: nil
  defp new_mem({min, _max}), do: :atomics.new(max(1, min) * 65536, signed: false)

  # mutable globals as an `:atomics` array; initial values come from each global's const init expression.
  defp new_globals([]), do: nil

  defp new_globals(globals) do
    ref = :atomics.new(length(globals), signed: false)
    stub = %{mod: nil, mem: nil, globals: nil}

    globals
    |> Enum.with_index(1)
    |> Enum.each(fn {init, ix} ->
      {_sig, [v | _], _l} = run(init, [], {}, stub)
      :atomics.put(ref, ix, v)
    end)

    ref
  end

  # Build the function table (idx => global func index) from active element segments — for call_indirect.
  defp new_table([], _globals), do: %{}

  defp new_table(elements, globals) do
    stub = %{mod: nil, mem: nil, globals: globals, table: %{}}

    Enum.reduce(elements, %{}, fn {offset, funcs}, acc ->
      {_sig, [base | _], _l} = run(offset, [], {}, stub)
      funcs |> Enum.with_index() |> Enum.reduce(acc, fn {f, i}, a -> Map.put(a, base + i, f) end)
    end)
  end

  # Copy each ACTIVE data segment's bytes into linear memory at its (const-expr) offset.
  defp init_data(_mem, _globals, []), do: :ok

  defp init_data(mem, globals, data) do
    stub = %{mod: nil, mem: nil, globals: globals}

    Enum.each(data, fn
      {:passive, _bytes} ->
        :ok

      {:active, offset_expr, bytes} ->
        {_sig, [addr | _], _l} = run(offset_expr, [], {}, stub)
        bytes |> :binary.bin_to_list() |> Enum.with_index() |> Enum.each(fn {b, i} -> store(mem, addr + i, b, 1) end)
    end)
  end

  # The function index space: imports occupy [0, n_imports); local funcs follow. Dispatch a global index.
  defp call_fn(rt, fidx, args) do
    ni = length(rt.mod.imports)
    if fidx < ni,
      do: call_host(rt, Enum.at(rt.mod.imports, fidx), args),
      else: invoke(rt, fidx - ni, args)
  end

  # Invoke LOCAL function `local_idx`: zero-extend declared locals after the args, run the structured body.
  defp invoke(rt, local_idx, args) do
    {nlocals, instrs} = Enum.at(rt.mod.code, local_idx)
    locals = (args ++ List.duplicate(0, nlocals)) |> List.to_tuple()
    {_sig, stack, _l} = run(instrs, [], locals, rt)
    case stack do
      [top | _] -> top
      [] -> nil
    end
  end

  # HOST IMPORTS = pure Elixir functions (this is the host-mediation seam — caps/tenant/Membrane live here).
  # WASI `fd_write(fd, iovs, iovs_len, nwritten_ptr)`: gather the iovec byte ranges from memory, capture
  # writes to stdout/stderr, store the byte count, return errno 0.
  defp call_host(rt, {_m, "fd_write", _t}, [fd, iovs, iovs_len, nwritten]) do
    total =
      Enum.reduce(0..(iovs_len - 1)//1, 0, fn i, acc ->
        base = load(rt.mem, iovs + i * 8, 4)
        len = load(rt.mem, iovs + i * 8 + 4, 4)

        if len > 0 do
          data = for(j <- 0..(len - 1)//1, do: load(rt.mem, base + j, 1)) |> :erlang.list_to_binary()
          if fd in [1, 2], do: Process.put(:washy_out, [data | Process.get(:washy_out, [])])
        end

        acc + len
      end)

    store(rt.mem, nwritten, total, 4)
    0
  end

  defp call_host(_rt, {_m, "proc_exit", _t}, [code]), do: throw({:washy_exit, code})
  defp call_host(_rt, {_m, name, _t}, _args), do: raise("washy: unimplemented host import '#{name}'")

  # Type-driven arity for a global function index (import or local).
  defp func_arity(mod, fidx) do
    ni = length(mod.imports)

    tidx =
      if fidx < ni do
        {_, _, t} = Enum.at(mod.imports, fidx)
        t
      else
        Enum.at(mod.funcs, fidx - ni)
      end

    {params, _} = Enum.at(mod.types, tidx)
    length(params)
  end

  # Run an instruction list, threading the operand stack + locals. Returns a SIGNAL so structured control
  # flow works: `{:next, stack, l}` (fell through), `{:br, n, stack, l}` (branch out n labels), or
  # `{:return, stack, l}`. A br/return stops the list and propagates up to the enclosing block/loop.
  defp run([], stack, l, _rt), do: {:next, stack, l}

  defp run([instr | rest], stack, l, rt) do
    case step(instr, stack, l, rt) do
      {:next, stack, l} -> run(rest, stack, l, rt)
      other -> other
    end
  end

  # block: a `br 0` exits to AFTER the block; deeper br decrements and propagates.
  defp step({:block, body}, stack, l, rt) do
    case run(body, stack, l, rt) do
      {:next, s, l} -> {:next, s, l}
      {:br, 0, s, l} -> {:next, s, l}
      {:br, n, s, l} -> {:br, n - 1, s, l}
      {:return, s, l} -> {:return, s, l}
    end
  end

  # loop: a `br 0` jumps to the START (re-run the loop); falling through exits.
  defp step({:loop, body} = loop, stack, l, rt) do
    case run(body, stack, l, rt) do
      {:next, s, l} -> {:next, s, l}
      {:br, 0, s, l} -> step(loop, s, l, rt)
      {:br, n, s, l} -> {:br, n - 1, s, l}
      {:return, s, l} -> {:return, s, l}
    end
  end

  defp step({:if, then_b, else_b}, [c | stack], l, rt) do
    case run(if(c != 0, do: then_b, else: else_b), stack, l, rt) do
      {:next, s, l} -> {:next, s, l}
      {:br, 0, s, l} -> {:next, s, l}
      {:br, n, s, l} -> {:br, n - 1, s, l}
      {:return, s, l} -> {:return, s, l}
    end
  end

  defp step({:br, n}, stack, l, _rt), do: {:br, n, stack, l}
  defp step({:br_if, n}, [c | stack], l, _rt), do: if(c != 0, do: {:br, n, stack, l}, else: {:next, stack, l})
  defp step({:return}, stack, l, _rt), do: {:return, stack, l}
  defp step({:unreachable}, _stack, _l, _rt), do: raise("washy: unreachable")
  defp step({:nop}, stack, l, _rt), do: {:next, stack, l}
  defp step({:drop}, [_ | stack], l, _rt), do: {:next, stack, l}

  defp step({:i64_const, v}, stack, l, _rt), do: {:next, [v | stack], l}

  defp step({:i64_load, o, n, signed}, [a | s], l, rt) do
    v = load(rt.mem, a + o, n)
    v = if signed, do: sext64(v, n * 8), else: v
    {:next, [v | s], l}
  end

  defp step({:i64_store, o, n}, [v, a | s], l, rt), do: (store(rt.mem, a + o, v, n); {:next, s, l})

  defp step({:global_get, i}, stack, l, rt), do: {:next, [:atomics.get(rt.globals, i + 1) | stack], l}
  defp step({:global_set, i}, [v | stack], l, rt), do: (:atomics.put(rt.globals, i + 1, v &&& @mask32); {:next, stack, l})
  defp step({:i32_const, v}, stack, l, _rt), do: {:next, [v &&& @mask32 | stack], l}
  defp step({:local_get, i}, stack, l, _rt), do: {:next, [elem(l, i) | stack], l}
  defp step({:local_set, i}, [v | stack], l, _rt), do: {:next, stack, put_elem(l, i, v)}
  defp step({:local_tee, i}, [v | _] = stack, l, _rt), do: {:next, stack, put_elem(l, i, v)}

  defp step({:call, f}, stack, l, rt) do
    {args, stack} = Enum.split(stack, func_arity(rt.mod, f))
    result = call_fn(rt, f, Enum.reverse(args))
    # a void function returns nil (empty result stack) — don't push it
    {:next, if(result == nil, do: stack, else: [result | stack]), l}
  end

  defp step({:call_indirect, _typeidx}, [i | stack], l, rt) do
    f = Map.fetch!(rt.table, i)
    {args, stack} = Enum.split(stack, func_arity(rt.mod, f))
    result = call_fn(rt, f, Enum.reverse(args))
    {:next, if(result == nil, do: stack, else: [result | stack]), l}
  end

  defp step({:i32_load, o}, [a | s], l, rt), do: {:next, [load(rt.mem, a + o, 4) | s], l}
  defp step({:i32_load8u, o}, [a | s], l, rt), do: {:next, [load(rt.mem, a + o, 1) | s], l}
  defp step({:i32_load8s, o}, [a | s], l, rt), do: {:next, [sext(load(rt.mem, a + o, 1), 8) | s], l}
  defp step({:i32_load16u, o}, [a | s], l, rt), do: {:next, [load(rt.mem, a + o, 2) | s], l}
  defp step({:i32_load16s, o}, [a | s], l, rt), do: {:next, [sext(load(rt.mem, a + o, 2), 16) | s], l}
  defp step({:i32_store, o}, [v, a | s], l, rt), do: (store(rt.mem, a + o, v, 4); {:next, s, l})
  defp step({:i32_store8, o}, [v, a | s], l, rt), do: (store(rt.mem, a + o, v, 1); {:next, s, l})
  defp step({:i32_store16, o}, [v, a | s], l, rt), do: (store(rt.mem, a + o, v, 2); {:next, s, l})
  defp step({:memory_size}, stack, l, rt), do: {:next, [div(:atomics.info(rt.mem).size, 65536) | stack], l}
  defp step({:memory_grow}, [_n | s], l, _rt), do: {:next, [-1 &&& @mask32 | s], l}   # TODO real grow

  # floats live on the stack as BEAM floats (heterogeneous w/ ints — validation keeps types correct).
  defp step({:fconst, v}, stack, l, _rt), do: {:next, [v | stack], l}
  defp step({:f32_load, o}, [a | s], l, rt), do: {:next, [fload(rt.mem, a + o, 4) | s], l}
  defp step({:f64_load, o}, [a | s], l, rt), do: {:next, [fload(rt.mem, a + o, 8) | s], l}
  defp step({:f32_store, o}, [v, a | s], l, rt), do: (fstore(rt.mem, a + o, v, 4); {:next, s, l})
  defp step({:f64_store, o}, [v, a | s], l, rt), do: (fstore(rt.mem, a + o, v, 8); {:next, s, l})

  defp step({:op, op}, stack, l, _rt), do: {:next, binop(op, stack), l}

  # ── pure stack ops: arithmetic + comparisons. `[b, a | s]` — a pushed first, b on top. ──
  defp binop(0x1B, [c, b, a | s]), do: [if(c != 0, do: a, else: b) | s]             # select
  defp binop(0x67, [a | s]), do: [clz(a, 32) | s]                                   # i32.clz
  defp binop(0x68, [a | s]), do: [ctz(a, 32) | s]                                   # i32.ctz
  defp binop(0x69, [a | s]), do: [pop(a) | s]                                       # i32.popcnt
  defp binop(0x6A, [b, a | s]), do: [(a + b) &&& @mask32 | s]                       # i32.add
  defp binop(0x6B, [b, a | s]), do: [(a - b) &&& @mask32 | s]                       # i32.sub
  defp binop(0x6C, [b, a | s]), do: [(a * b) &&& @mask32 | s]                       # i32.mul
  defp binop(0x6D, [b, a | s]), do: [div(s32(a), s32(b)) &&& @mask32 | s]           # i32.div_s
  defp binop(0x6E, [b, a | s]), do: [div(a, b) &&& @mask32 | s]                     # i32.div_u
  defp binop(0x6F, [b, a | s]), do: [rem(s32(a), s32(b)) &&& @mask32 | s]           # i32.rem_s
  defp binop(0x70, [b, a | s]), do: [rem(a, b) &&& @mask32 | s]                     # i32.rem_u
  defp binop(0x71, [b, a | s]), do: [a &&& b | s]                                   # i32.and
  defp binop(0x72, [b, a | s]), do: [a ||| b | s]                                   # i32.or
  defp binop(0x73, [b, a | s]), do: [bxor(a, b) | s]                                # i32.xor
  defp binop(0x74, [b, a | s]), do: [(a <<< (b &&& 31)) &&& @mask32 | s]            # i32.shl
  defp binop(0x75, [b, a | s]), do: [(s32(a) >>> (b &&& 31)) &&& @mask32 | s]       # i32.shr_s
  defp binop(0x76, [b, a | s]), do: [a >>> (b &&& 31) | s]                          # i32.shr_u
  defp binop(0x77, [b, a | s]), do: [rotl32(a, b &&& 31) | s]                       # i32.rotl
  defp binop(0x78, [b, a | s]), do: [rotr32(a, b &&& 31) | s]                       # i32.rotr
  defp binop(0x45, [a | s]), do: [bool(a == 0) | s]                                 # i32.eqz
  defp binop(0x46, [b, a | s]), do: [bool(a == b) | s]                              # i32.eq
  defp binop(0x47, [b, a | s]), do: [bool(a != b) | s]                              # i32.ne
  defp binop(0x48, [b, a | s]), do: [bool(s32(a) < s32(b)) | s]                     # i32.lt_s
  defp binop(0x49, [b, a | s]), do: [bool(a < b) | s]                               # i32.lt_u
  defp binop(0x4A, [b, a | s]), do: [bool(s32(a) > s32(b)) | s]                     # i32.gt_s
  defp binop(0x4B, [b, a | s]), do: [bool(a > b) | s]                               # i32.gt_u
  defp binop(0x4C, [b, a | s]), do: [bool(s32(a) <= s32(b)) | s]                    # i32.le_s
  defp binop(0x4D, [b, a | s]), do: [bool(a <= b) | s]                              # i32.le_u
  defp binop(0x4E, [b, a | s]), do: [bool(s32(a) >= s32(b)) | s]                    # i32.ge_s
  defp binop(0x4F, [b, a | s]), do: [bool(a >= b) | s]                              # i32.ge_u
  # ── f32 (round results to single precision) ──
  defp binop(0x8B, [a | s]), do: [abs(a) | s]                                       # f32.abs
  defp binop(0x8C, [a | s]), do: [-a | s]                                           # f32.neg
  defp binop(0x91, [a | s]), do: [f32r(:math.sqrt(a)) | s]                          # f32.sqrt
  defp binop(0x92, [b, a | s]), do: [f32r(a + b) | s]                               # f32.add
  defp binop(0x93, [b, a | s]), do: [f32r(a - b) | s]                               # f32.sub
  defp binop(0x94, [b, a | s]), do: [f32r(a * b) | s]                               # f32.mul
  defp binop(0x95, [b, a | s]), do: [f32r(a / b) | s]                               # f32.div
  defp binop(0x96, [b, a | s]), do: [min(a, b) | s]                                 # f32.min
  defp binop(0x97, [b, a | s]), do: [max(a, b) | s]                                 # f32.max
  defp binop(0x5B, [b, a | s]), do: [bool(a == b) | s]                              # f32.eq
  defp binop(0x5C, [b, a | s]), do: [bool(a != b) | s]                              # f32.ne
  defp binop(0x5D, [b, a | s]), do: [bool(a < b) | s]                               # f32.lt
  defp binop(0x5E, [b, a | s]), do: [bool(a > b) | s]                               # f32.gt
  defp binop(0x5F, [b, a | s]), do: [bool(a <= b) | s]                              # f32.le
  defp binop(0x60, [b, a | s]), do: [bool(a >= b) | s]                              # f32.ge
  # ── f64 ──
  defp binop(0x99, [a | s]), do: [abs(a) | s]                                       # f64.abs
  defp binop(0x9A, [a | s]), do: [-a | s]                                           # f64.neg
  defp binop(0x9F, [a | s]), do: [:math.sqrt(a) | s]                                # f64.sqrt
  defp binop(0xA0, [b, a | s]), do: [a + b | s]                                     # f64.add
  defp binop(0xA1, [b, a | s]), do: [a - b | s]                                     # f64.sub
  defp binop(0xA2, [b, a | s]), do: [a * b | s]                                     # f64.mul
  defp binop(0xA3, [b, a | s]), do: [a / b | s]                                     # f64.div
  defp binop(0xA4, [b, a | s]), do: [min(a, b) | s]                                 # f64.min
  defp binop(0xA5, [b, a | s]), do: [max(a, b) | s]                                 # f64.max
  defp binop(0x61, [b, a | s]), do: [bool(a == b) | s]                              # f64.eq
  defp binop(0x62, [b, a | s]), do: [bool(a != b) | s]                              # f64.ne
  defp binop(0x63, [b, a | s]), do: [bool(a < b) | s]                               # f64.lt
  defp binop(0x64, [b, a | s]), do: [bool(a > b) | s]                               # f64.gt
  defp binop(0x65, [b, a | s]), do: [bool(a <= b) | s]                              # f64.le
  defp binop(0x66, [b, a | s]), do: [bool(a >= b) | s]                              # f64.ge
  # ── conversions (i32 ⇄ f32/f64) ──
  defp binop(0xA8, [a | s]), do: [trunc(a) &&& @mask32 | s]                         # i32.trunc_f32_s
  defp binop(0xA9, [a | s]), do: [trunc(a) &&& @mask32 | s]                         # i32.trunc_f32_u
  defp binop(0xAA, [a | s]), do: [trunc(a) &&& @mask32 | s]                         # i32.trunc_f64_s
  defp binop(0xAB, [a | s]), do: [trunc(a) &&& @mask32 | s]                         # i32.trunc_f64_u
  defp binop(0xB2, [a | s]), do: [f32r(s32(a) * 1.0) | s]                           # f32.convert_i32_s
  defp binop(0xB3, [a | s]), do: [f32r(a * 1.0) | s]                                # f32.convert_i32_u
  defp binop(0xB6, [a | s]), do: [f32r(a) | s]                                      # f32.demote_f64
  defp binop(0xB7, [a | s]), do: [s32(a) * 1.0 | s]                                 # f64.convert_i32_s
  defp binop(0xB8, [a | s]), do: [a * 1.0 | s]                                      # f64.convert_i32_u
  defp binop(0xBB, [a | s]), do: [a * 1.0 | s]                                      # f64.promote_f32
  defp binop(0xBC, [a | s]), do: [(<<i::32-little>> = <<a::float-32-little>>; i) | s]  # i32.reinterpret_f32
  defp binop(0xBE, [a | s]), do: [(<<f::float-32-little>> = <<a::32-little>>; f) | s]  # f32.reinterpret_i32

  # ── i64 (BEAM integers masked to 64 bits) ──
  defp binop(0x50, [a | s]), do: [bool(a == 0) | s]                                 # i64.eqz
  defp binop(0x51, [b, a | s]), do: [bool(a == b) | s]                             # i64.eq
  defp binop(0x52, [b, a | s]), do: [bool(a != b) | s]                             # i64.ne
  defp binop(0x53, [b, a | s]), do: [bool(s64(a) < s64(b)) | s]                    # i64.lt_s
  defp binop(0x54, [b, a | s]), do: [bool(a < b) | s]                              # i64.lt_u
  defp binop(0x55, [b, a | s]), do: [bool(s64(a) > s64(b)) | s]                    # i64.gt_s
  defp binop(0x56, [b, a | s]), do: [bool(a > b) | s]                              # i64.gt_u
  defp binop(0x57, [b, a | s]), do: [bool(s64(a) <= s64(b)) | s]                   # i64.le_s
  defp binop(0x58, [b, a | s]), do: [bool(a <= b) | s]                             # i64.le_u
  defp binop(0x59, [b, a | s]), do: [bool(s64(a) >= s64(b)) | s]                   # i64.ge_s
  defp binop(0x5A, [b, a | s]), do: [bool(a >= b) | s]                             # i64.ge_u
  defp binop(0x79, [a | s]), do: [clz(a, 64) | s]                                  # i64.clz
  defp binop(0x7A, [a | s]), do: [ctz(a, 64) | s]                                  # i64.ctz
  defp binop(0x7B, [a | s]), do: [pop(a) | s]                                      # i64.popcnt
  defp binop(0x7C, [b, a | s]), do: [(a + b) &&& @mask64 | s]                       # i64.add
  defp binop(0x7D, [b, a | s]), do: [(a - b) &&& @mask64 | s]                       # i64.sub
  defp binop(0x7E, [b, a | s]), do: [(a * b) &&& @mask64 | s]                       # i64.mul
  defp binop(0x7F, [b, a | s]), do: [div(s64(a), s64(b)) &&& @mask64 | s]           # i64.div_s
  defp binop(0x80, [b, a | s]), do: [div(a, b) &&& @mask64 | s]                     # i64.div_u
  defp binop(0x81, [b, a | s]), do: [rem(s64(a), s64(b)) &&& @mask64 | s]           # i64.rem_s
  defp binop(0x82, [b, a | s]), do: [rem(a, b) &&& @mask64 | s]                     # i64.rem_u
  defp binop(0x83, [b, a | s]), do: [a &&& b | s]                                   # i64.and
  defp binop(0x84, [b, a | s]), do: [a ||| b | s]                                   # i64.or
  defp binop(0x85, [b, a | s]), do: [bxor(a, b) | s]                                # i64.xor
  defp binop(0x86, [b, a | s]), do: [(a <<< (b &&& 63)) &&& @mask64 | s]            # i64.shl
  defp binop(0x87, [b, a | s]), do: [(s64(a) >>> (b &&& 63)) &&& @mask64 | s]       # i64.shr_s
  defp binop(0x88, [b, a | s]), do: [a >>> (b &&& 63) | s]                          # i64.shr_u
  # conversions involving i64
  defp binop(0xA7, [a | s]), do: [a &&& @mask32 | s]                                # i32.wrap_i64
  defp binop(0xAC, [a | s]), do: [sext64(a, 32) | s]                               # i64.extend_i32_s
  defp binop(0xAD, [a | s]), do: [a &&& @mask64 | s]                               # i64.extend_i32_u
  defp binop(0xB0, [a | s]), do: [trunc(a) &&& @mask64 | s]                         # i64.trunc_f64_s
  defp binop(0xB1, [a | s]), do: [trunc(a) &&& @mask64 | s]                         # i64.trunc_f64_u
  defp binop(0xB9, [a | s]), do: [s64(a) * 1.0 | s]                                 # f64.convert_i64_s
  defp binop(0xBA, [a | s]), do: [a * 1.0 | s]                                      # f64.convert_i64_u

  defp binop(op, _), do: raise("washy: unimplemented stack op 0x#{Integer.to_string(op, 16)}")

  defp s64(x) when x >= 0x8000000000000000, do: x - 0x10000000000000000
  defp s64(x), do: x
  defp sext64(v, bits) when v >= 1 <<< (bits - 1), do: (v - (1 <<< bits)) &&& @mask64
  defp sext64(v, _bits), do: v

  # round a double to f32 precision (pack→unpack as 32-bit IEEE-754). NB: raises on NaN/Inf (refine later).
  defp f32r(x), do: (<<v::float-32-little>> = <<x::float-32-little>>; v)

  defp fload(mem, addr, n) do
    bin = for(i <- 0..(n - 1)//1, do: :atomics.get(mem, addr + i + 1)) |> :erlang.list_to_binary()
    case n do
      4 -> <<v::float-32-little>> = bin; v
      8 -> <<v::float-64-little>> = bin; v
    end
  end

  defp fstore(mem, addr, v, n) do
    bin = if n == 4, do: <<v::float-32-little>>, else: <<v::float-64-little>>
    bin |> :binary.bin_to_list() |> Enum.with_index() |> Enum.each(fn {b, i} -> :atomics.put(mem, addr + i + 1, b) end)
  end

  defp bool(true), do: 1
  defp bool(false), do: 0
  defp s32(x) when x >= 0x80000000, do: x - 0x100000000
  defp s32(x), do: x

  # sign-extend an n-bit value to the 32-bit unsigned representation
  defp sext(v, bits) do
    if v >= 1 <<< (bits - 1), do: (v - (1 <<< bits)) &&& @mask32, else: v
  end

  defp rotl32(a, 0), do: a
  defp rotl32(a, n), do: ((a <<< n) ||| (a >>> (32 - n))) &&& @mask32
  defp rotr32(a, 0), do: a
  defp rotr32(a, n), do: ((a >>> n) ||| (a <<< (32 - n))) &&& @mask32

  # precise bit-length (no float imprecision) → clz; ctz/pop by scanning bits
  defp bitlen(a, acc \\ 0)
  defp bitlen(0, acc), do: acc
  defp bitlen(a, acc), do: bitlen(a >>> 1, acc + 1)
  defp clz(a, bits), do: bits - bitlen(a)
  defp ctz(0, bits), do: bits
  defp ctz(a, _bits), do: ctz_(a, 0)
  defp ctz_(a, n), do: if((a &&& 1) == 1, do: n, else: ctz_(a >>> 1, n + 1))
  defp pop(a), do: pop_(a, 0)
  defp pop_(0, n), do: n
  defp pop_(a, n), do: pop_(a >>> 1, n + (a &&& 1))

  # memarg = align (uleb) + offset (uleb); we only need offset (alignment is a hint).
  defp memarg(bin) do
    {_align, bin} = uleb(bin)
    uleb(bin)
  end

  # byte-addressed load/store over the `:atomics` memory (1-indexed). Little-endian, `n` bytes.
  defp load(mem, addr, n) do
    Enum.reduce(0..(n - 1), 0, fn i, acc -> acc ||| (:atomics.get(mem, addr + i + 1) <<< (i * 8)) end)
  end

  defp store(mem, addr, val, n) do
    for i <- 0..(n - 1), do: :atomics.put(mem, addr + i + 1, (val >>> (i * 8)) &&& 0xFF)
    :ok
  end
end

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
  defp parse_op(0x0E, rest), do: ({labels, r} = vec(rest, &uleb/1); {default, r} = uleb(r); {{:br_table, labels, default}, r})
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
  # floats: const literals — read RAW bits (NaN/Inf can't be pattern-matched as an Erlang float), decode to
  # a float only when finite; a non-finite const becomes a placeholder (raises only if actually used).
  defp parse_op(0x43, <<bits::32-little, rest::binary>>), do: {{:fconst, decode_f(bits, 32)}, rest}
  defp parse_op(0x44, <<bits::64-little, rest::binary>>), do: {{:fconst, decode_f(bits, 64)}, rest}
  defp parse_op(0x2A, rest), do: ({o, r} = memarg(rest); {{:f32_load, o}, r})
  defp parse_op(0x2B, rest), do: ({o, r} = memarg(rest); {{:f64_load, o}, r})
  defp parse_op(0x38, rest), do: ({o, r} = memarg(rest); {{:f32_store, o}, r})
  defp parse_op(0x39, rest), do: ({o, r} = memarg(rest); {{:f64_store, o}, r})
  # 0xFC = the "misc" prefix (bulk memory + saturating truncations). Sub-opcode is a uleb.
  defp parse_op(0xFC, rest) do
    {sub, rest} = uleb(rest)

    case sub do
      8 -> {_data, r} = uleb(rest); <<_mem, r::binary>> = r; {{:memory_init}, r}
      9 -> {_data, r} = uleb(rest); {{:data_drop}, r}
      10 -> <<_dst, _src, r::binary>> = rest; {{:memory_copy}, r}
      11 -> <<_mem, r::binary>> = rest; {{:memory_fill}, r}
      n when n in 0..7 -> {{:trunc_sat, n}, rest}
      _ -> raise("washy: unimplemented 0xFC sub-op #{sub}")
    end
  end

  # 0xFD = SIMD (v128) prefix. We parse PAST it (correct immediate per sub-op) so SIMD-using modules
  # decode; execution of a v128 op raises (unimplemented) — fine if the run never hits one.
  defp parse_op(0xFD, rest) do
    {sub, rest} = uleb(rest)

    {imm, rest} =
      cond do
        sub in 0..11 or sub in [92, 93] -> memarg(rest)
        sub in [12, 13] -> (<<c::binary-size(16), r::binary>> = rest; {c, r})
        sub in 21..34 -> (<<lane, r::binary>> = rest; {lane, r})
        sub in 84..91 -> ({o, r} = memarg(rest); <<lane, r2::binary>> = r; {{o, lane}, r2})
        true -> {nil, rest}
      end

    {{:simd, sub, imm}, rest}
  end

  # the pure numeric/compare/convert ops (no immediate) — a contiguous range; dispatch by opcode
  defp parse_op(op, rest) when op == 0x1B or (op >= 0x45 and op <= 0xC4), do: {{:op, op}, rest}
  # anything else carries an immediate we haven't taught the parser — fail LOUDLY with the exact opcode
  defp parse_op(op, _rest), do: raise("washy parser: unhandled opcode 0x#{Integer.to_string(op, 16)} (needs an immediate-aware clause)")

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
    {mem, mem_pages} = new_mem(mod.mem)
    init_data(mem, globals, mod.data)
    rt = %{mod: mod, mem: mem, mem_pages: mem_pages, globals: globals, table: new_table(mod.elements, globals)}
    result = call_fn(rt, Map.fetch!(mod.exports, name), args)
    out = Process.get(:washy_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
    if prev == nil, do: Process.delete(:washy_out), else: Process.put(:washy_out, prev)
    {result, out}
  end

  # Linear memory: one `:atomics` slot per byte (pack-to-words is a later optimization). We pre-allocate a
  # generous CAP so `memory.grow` works (grow just raises the logical page count, tracked in a 1-slot
  # atomics). Returns `{backing, pages_ref}`. nil = no memory.
  @cap_pages 64
  defp new_mem(nil), do: {nil, nil}

  defp new_mem({min, _max}) do
    cap = max(min, @cap_pages)
    backing = :atomics.new(cap * 65536, signed: false)
    pages = :atomics.new(1, signed: false)
    :atomics.put(pages, 1, max(1, min))
    {backing, pages}
  end

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
    data = gather_iovs(rt.mem, iovs, iovs_len)
    cond do
      fd in [1, 2] -> Process.put(:washy_out, [data | Process.get(:washy_out, [])])
      true -> file_write(fd, data)
    end

    store(rt.mem, nwritten, byte_size(data), 4)
    0
  end

  defp call_host(_rt, {_m, "proc_exit", _t}, [code]), do: throw({:washy_exit, code})

  # WASI args (argv): argc < 2 so the shell reads its command line from stdin.
  defp call_host(rt, {_m, "args_sizes_get", _t}, [argc_ptr, bufsize_ptr]) do
    argv = Process.get(:washy_argv, ["sh"])
    store(rt.mem, argc_ptr, length(argv), 4)
    store(rt.mem, bufsize_ptr, Enum.reduce(argv, 0, fn a, acc -> acc + byte_size(a) + 1 end), 4)
    0
  end

  defp call_host(rt, {_m, "args_get", _t}, [argv_ptr, buf_ptr]) do
    Process.get(:washy_argv, ["sh"])
    |> Enum.reduce({argv_ptr, buf_ptr}, fn a, {pp, bp} ->
      store(rt.mem, pp, bp, 4)
      write_bytes(rt.mem, bp, a)
      store(rt.mem, bp + byte_size(a), 0, 1)
      {pp + 4, bp + byte_size(a) + 1}
    end)

    0
  end

  # WASI read: fd 0 = stdin (command line); a file fd = the virtual filesystem; else EOF.
  defp call_host(rt, {_m, "fd_read", _t}, [fd, iovs, iovs_len, nread_ptr]) do
    cap = iov_capacity(rt.mem, iovs, iovs_len)
    data = if fd == 0, do: stdin_take(cap), else: file_read(fd, cap)
    store(rt.mem, nread_ptr, scatter_iovs(rt.mem, iovs, iovs_len, data), 4)
    0
  end

  # fd metadata: a file fd is a regular file (4); stdin/out/err are character devices (2).
  defp call_host(rt, {_m, "fd_fdstat_get", _t}, [fd, ptr]) do
    ft = if Map.has_key?(Process.get(:washy_fds, %{}), fd), do: 4, else: 2
    store(rt.mem, ptr, ft, 1)
    0
  end

  # ONE preopened dir at fd 3 = the virtual /work, so the shell resolves /work/<path> against it.
  defp call_host(rt, {_m, "fd_prestat_get", _t}, [3, ptr]) do
    store(rt.mem, ptr, 0, 1)
    store(rt.mem, ptr + 4, byte_size(preopen_name()), 4)
    0
  end

  defp call_host(_rt, {_m, "fd_prestat_get", _t}, [_fd, _ptr]), do: 8

  defp call_host(rt, {_m, "fd_prestat_dir_name", _t}, [3, ptr, len]) do
    name = preopen_name()
    write_bytes(rt.mem, ptr, binary_part(name, 0, min(len, byte_size(name))))
    0
  end

  defp call_host(_rt, {_m, "fd_prestat_dir_name", _t}, _args), do: 8

  # open a path (relative to the /work preopen) in the virtual FS — create/truncate per oflags.
  defp call_host(rt, {_m, "path_open", _t}, [_dirfd, _df, path_ptr, path_len, oflags, _rb, _ri, _ff, ofd_ptr]) do
    rel = read_bytes(rt.mem, path_ptr, path_len)
    exists = Nexus.Washy.VFS.has?(rel)
    creat = (oflags &&& 1) != 0
    trunc = (oflags &&& 8) != 0

    if not exists and not creat do
      44
    else
      if not exists or trunc, do: Nexus.Washy.VFS.put(rel, "")
      fd = Process.get(:washy_nextfd, 4)
      Process.put(:washy_nextfd, fd + 1)
      Process.put(:washy_fds, Map.put(Process.get(:washy_fds, %{}), fd, {rel, 0}))
      store(rt.mem, ofd_ptr, fd, 4)
      0
    end
  end

  defp call_host(_rt, {_m, "fd_close", _t}, [fd]) do
    Process.put(:washy_fds, Map.delete(Process.get(:washy_fds, %{}), fd))
    0
  end

  defp call_host(rt, {_m, "fd_seek", _t}, [fd, offset, whence, ofs_ptr]) do
    fds = Process.get(:washy_fds, %{})

    case Map.get(fds, fd) do
      {path, off} ->
        size = byte_size(Nexus.Washy.VFS.get(path) || "")
        base = case whence do
          0 -> 0
          1 -> off
          2 -> size
          _ -> 0
        end
        noff = base + s64(offset)
        Process.put(:washy_fds, Map.put(fds, fd, {path, noff}))
        store(rt.mem, ofs_ptr, noff, 8)
        0

      _ ->
        70
    end
  end

  # environment (empty), clock, randomness, scheduling — host-mediated, pure Elixir.
  defp call_host(rt, {_m, "environ_sizes_get", _t}, [c_ptr, b_ptr]), do: (store(rt.mem, c_ptr, 0, 4); store(rt.mem, b_ptr, 0, 4); 0)
  defp call_host(_rt, {_m, "environ_get", _t}, _args), do: 0
  defp call_host(rt, {_m, "clock_time_get", _t}, [_id, _prec, time_ptr]), do: (store(rt.mem, time_ptr, Process.get(:washy_clock, 0), 8); 0)
  defp call_host(rt, {_m, "random_get", _t}, [buf, len]), do: (write_bytes(rt.mem, buf, :binary.copy(<<0>>, len)); 0)
  defp call_host(_rt, {_m, "sched_yield", _t}, _args), do: 0
  defp call_host(_rt, {_m, "fd_sync", _t}, _args), do: 0
  defp call_host(_rt, {_m, "fd_datasync", _t}, _args), do: 0

  # file stat: report a regular file with the VFS content's size; dir/path ops succeed minimally.
  defp call_host(rt, {_m, "fd_filestat_get", _t}, [fd, ptr]) do
    size = case Map.get(Process.get(:washy_fds, %{}), fd) do
      {path, _} -> byte_size(Nexus.Washy.VFS.get(path) || "")
      _ -> 0
    end
    # filestat: dev(8) ino(8) filetype(1) +pad(7) nlink(8) size(8) atim(8) mtim(8) ctim(8)
    store(rt.mem, ptr + 16, 4, 1)
    store(rt.mem, ptr + 32, size, 8)
    0
  end

  defp call_host(rt, {_m, "path_filestat_get", _t}, [_dirfd, _flags, path_ptr, path_len, ptr | _]) do
    rel = read_bytes(rt.mem, path_ptr, path_len)
    case Nexus.Washy.VFS.get(rel) do
      nil -> 44
      content -> (store(rt.mem, ptr + 16, 4, 1); store(rt.mem, ptr + 32, byte_size(content), 8); 0)
    end
  end

  defp call_host(rt, {_m, "fd_tell", _t}, [fd, ptr]) do
    off = case Map.get(Process.get(:washy_fds, %{}), fd) do
      {_path, o} -> o
      _ -> 0
    end
    store(rt.mem, ptr, off, 8)
    0
  end

  defp call_host(_rt, {_m, "fd_filestat_set_size", _t}, _args), do: 0
  defp call_host(_rt, {_m, "fd_filestat_set_times", _t}, _args), do: 0
  defp call_host(_rt, {_m, "fd_readdir", _t}, _args), do: 8
  defp call_host(_rt, {_m, "poll_oneoff", _t}, _args), do: 0
  defp call_host(_rt, {_m, "path_create_directory", _t}, _args), do: 0
  defp call_host(_rt, {_m, "path_remove_directory", _t}, _args), do: 0
  defp call_host(_rt, {_m, "path_unlink_file", _t}, _args), do: 0
  defp call_host(_rt, {_m, "path_rename", _t}, _args), do: 0
  defp call_host(_rt, {_m, "path_link", _t}, _args), do: 0
  defp call_host(_rt, {_m, "path_symlink", _t}, _args), do: 0
  defp call_host(_rt, {_m, "path_readlink", _t}, _args), do: 44

  defp call_host(_rt, {_m, name, _t}, _args), do: raise("washy: unimplemented host import '#{name}'")

  defp write_bytes(mem, addr, bin) do
    bin |> :binary.bin_to_list() |> Enum.with_index() |> Enum.each(fn {b, i} -> store(mem, addr + i, b, 1) end)
  end

  defp stdin_take(n) do
    buf = Process.get(:washy_stdin, "")
    take = min(n, byte_size(buf))
    <<chunk::binary-size(take), rest::binary>> = buf
    Process.put(:washy_stdin, rest)
    chunk
  end

  # ── the virtual filesystem (files as an Elixir map: relpath => bytes; the node-graph model) ──────
  defp preopen_name, do: "/work"

  defp gather_iovs(mem, iovs, n) do
    for(i <- 0..(n - 1)//1, do: read_bytes(mem, load(mem, iovs + i * 8, 4), load(mem, iovs + i * 8 + 4, 4)))
    |> IO.iodata_to_binary()
  end

  defp iov_capacity(mem, iovs, n), do: Enum.reduce(0..(n - 1)//1, 0, fn i, acc -> acc + load(mem, iovs + i * 8 + 4, 4) end)

  defp scatter_iovs(mem, iovs, n, data) do
    {written, _} =
      Enum.reduce(0..(n - 1)//1, {0, data}, fn i, {w, rem} ->
        base = load(mem, iovs + i * 8, 4)
        len = load(mem, iovs + i * 8 + 4, 4)
        take = min(len, byte_size(rem))
        <<chunk::binary-size(take), rest::binary>> = rem
        write_bytes(mem, base, chunk)
        {w + take, rest}
      end)

    written
  end

  defp read_bytes(_mem, _addr, 0), do: ""
  defp read_bytes(mem, addr, len), do: for(j <- 0..(len - 1)//1, do: load(mem, addr + j, 1)) |> :erlang.list_to_binary()

  defp file_read(fd, n) do
    fds = Process.get(:washy_fds, %{})

    case Map.get(fds, fd) do
      {path, off} ->
        content = Nexus.Washy.VFS.get(path) || ""
        take = max(0, min(n, byte_size(content) - off))
        chunk = if take > 0, do: binary_part(content, off, take), else: ""
        Process.put(:washy_fds, Map.put(fds, fd, {path, off + take}))
        chunk

      _ ->
        ""
    end
  end

  defp file_write(fd, data) do
    fds = Process.get(:washy_fds, %{})

    case Map.get(fds, fd) do
      {path, off} ->
        content = pad_to(Nexus.Washy.VFS.get(path) || "", off)
        tail_start = off + byte_size(data)
        post = if byte_size(content) > tail_start, do: binary_part(content, tail_start, byte_size(content) - tail_start), else: ""
        Nexus.Washy.VFS.put(path, binary_part(content, 0, off) <> data <> post)
        Process.put(:washy_fds, Map.put(fds, fd, {path, tail_start}))

      _ ->
        :ok
    end
  end

  defp pad_to(bin, n) when byte_size(bin) >= n, do: bin
  defp pad_to(bin, n), do: bin <> :binary.copy(<<0>>, n - byte_size(bin))

  # v128 load/store: 16 bytes <-> a 16-byte binary
  defp vload(mem, addr), do: for(i <- 0..15, do: :atomics.get(mem, addr + i + 1)) |> :erlang.list_to_binary()
  defp vstore(mem, addr, <<bytes::binary-size(16)>>), do: bytes |> :binary.bin_to_list() |> Enum.with_index() |> Enum.each(fn {b, i} -> :atomics.put(mem, addr + i + 1, b) end)

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

  defp step({:br_table, labels, default}, [i | stack], l, _rt) do
    target = if i < length(labels), do: Enum.at(labels, i), else: default
    {:br, target, stack, l}
  end
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
  defp step({:memory_size}, stack, l, rt), do: {:next, [:atomics.get(rt.mem_pages, 1) | stack], l}

  defp step({:memory_grow}, [n | s], l, rt) do
    old = :atomics.get(rt.mem_pages, 1)
    cap = div(:atomics.info(rt.mem).size, 65536)
    result = if old + n <= cap, do: (:atomics.put(rt.mem_pages, 1, old + n); old), else: -1 &&& @mask32
    {:next, [result | s], l}
  end

  # bulk memory: copy n bytes src->dst (overlap-safe); fill n bytes at dst with a byte value
  defp step({:memory_copy}, [n, src, dst | s], l, rt), do: (if n > 0, do: mem_copy(rt.mem, dst, src, n); {:next, s, l})
  defp step({:memory_fill}, [n, val, dst | s], l, rt), do: (for(i <- 0..(n - 1)//1, do: store(rt.mem, dst + i, val, 1)); {:next, s, l})
  defp step({:data_drop}, stack, l, _rt), do: {:next, stack, l}
  defp step({:trunc_sat, n}, [a | s], l, _rt) when n in 0..3, do: {:next, [trunc_sat(a) &&& @mask32 | s], l}
  defp step({:trunc_sat, _n}, [a | s], l, _rt), do: {:next, [trunc_sat(a) &&& @mask64 | s], l}

  # floats live on the stack as BEAM floats (heterogeneous w/ ints — validation keeps types correct).
  defp step({:fconst, v}, stack, l, _rt), do: {:next, [v | stack], l}
  defp step({:f32_load, o}, [a | s], l, rt), do: {:next, [fload(rt.mem, a + o, 4) | s], l}
  defp step({:f64_load, o}, [a | s], l, rt), do: {:next, [fload(rt.mem, a + o, 8) | s], l}
  defp step({:f32_store, o}, [v, a | s], l, rt), do: (fstore(rt.mem, a + o, v, 4); {:next, s, l})
  defp step({:f64_store, o}, [v, a | s], l, rt), do: (fstore(rt.mem, a + o, v, 8); {:next, s, l})

  # v128 values live on the stack as 16-byte binaries.
  defp step({:simd, 0, off}, [a | s], l, rt), do: {:next, [vload(rt.mem, a + off) | s], l}      # v128.load
  defp step({:simd, 11, off}, [v, a | s], l, rt), do: (vstore(rt.mem, a + off, v); {:next, s, l})  # v128.store
  defp step({:simd, 12, c}, s, l, _rt), do: {:next, [c | s], l}                                   # v128.const
  defp step({:simd, sub, _imm}, _stack, _l, _rt), do: raise("washy: unimplemented SIMD op 0xFD #{sub}")
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
  defp binop(0x89, [b, a | s]), do: [rotl64(a, b &&& 63) | s]                       # i64.rotl
  defp binop(0x8A, [b, a | s]), do: [rotr64(a, b &&& 63) | s]                       # i64.rotr
  # conversions involving i64
  defp binop(0xA7, [a | s]), do: [a &&& @mask32 | s]                                # i32.wrap_i64
  defp binop(0xAC, [a | s]), do: [sext64(a, 32) | s]                               # i64.extend_i32_s
  defp binop(0xAD, [a | s]), do: [a &&& @mask64 | s]                               # i64.extend_i32_u
  defp binop(0xB0, [a | s]), do: [trunc(a) &&& @mask64 | s]                         # i64.trunc_f64_s
  defp binop(0xB1, [a | s]), do: [trunc(a) &&& @mask64 | s]                         # i64.trunc_f64_u
  defp binop(0xB9, [a | s]), do: [s64(a) * 1.0 | s]                                 # f64.convert_i64_s
  defp binop(0xBA, [a | s]), do: [a * 1.0 | s]                                      # f64.convert_i64_u

  # sign-extension ops (within a type)
  defp binop(0xC0, [a | s]), do: [sext(a &&& 0xFF, 8) | s]                          # i32.extend8_s
  defp binop(0xC1, [a | s]), do: [sext(a &&& 0xFFFF, 16) | s]                       # i32.extend16_s
  defp binop(0xC2, [a | s]), do: [sext64(a &&& 0xFF, 8) | s]                        # i64.extend8_s
  defp binop(0xC3, [a | s]), do: [sext64(a &&& 0xFFFF, 16) | s]                     # i64.extend16_s
  defp binop(0xC4, [a | s]), do: [sext64(a &&& @mask32, 32) | s]                    # i64.extend32_s

  defp binop(op, _), do: raise("washy: unimplemented stack op 0x#{Integer.to_string(op, 16)}")

  defp s64(x) when x >= 0x8000000000000000, do: x - 0x10000000000000000
  defp s64(x), do: x
  defp sext64(v, bits) when v >= 1 <<< (bits - 1), do: (v - (1 <<< bits)) &&& @mask64
  defp sext64(v, _bits), do: v

  # round a double to f32 precision (pack→unpack as 32-bit IEEE-754). NB: raises on NaN/Inf (refine later).
  defp f32r(x), do: (<<v::float-32-little>> = <<x::float-32-little>>; v)

  # decode raw IEEE-754 bits → a BEAM float when finite, else a non-finite placeholder (BEAM has no NaN/Inf)
  defp decode_f(bits, size) do
    bin = <<bits::size(size)-little>>

    try do
      case size do
        32 -> <<f::float-32-little>> = bin; f
        64 -> <<f::float-64-little>> = bin; f
      end
    rescue
      _ -> {:nonfinite, bits, size}
    end
  end

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

  # copy n bytes within memory, src->dst, overlap-safe (forward when dst<=src, else backward)
  defp mem_copy(mem, dst, src, n) when dst <= src,
    do: for(i <- 0..(n - 1)//1, do: :atomics.put(mem, dst + i + 1, :atomics.get(mem, src + i + 1)))

  defp mem_copy(mem, dst, src, n),
    do: for(i <- (n - 1)..0//-1, do: :atomics.put(mem, dst + i + 1, :atomics.get(mem, src + i + 1)))

  # saturating float→int truncation: NaN→0, else truncate (simple; clamp edges refined later)
  defp trunc_sat(a) when is_float(a), do: trunc(a)
  defp trunc_sat(a), do: a

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
  defp rotl64(a, 0), do: a
  defp rotl64(a, n), do: ((a <<< n) ||| (a >>> (64 - n))) &&& @mask64
  defp rotr64(a, 0), do: a
  defp rotr64(a, n), do: ((a >>> n) ||| (a <<< (64 - n))) &&& @mask64

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

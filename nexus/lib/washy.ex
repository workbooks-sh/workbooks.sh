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
  import Nexus.Washy.Trap, only: [trap!: 1]

  defstruct types: [], funcs: [], exports: %{}, code: [], mem: nil, imports: [], globals: [], data: [], elements: [], table_type: nil, tags: [], id: nil

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

  @doc """
  Decode with a **content-addressed cache**: the immutable module struct is decoded ONCE per unique
  binary and stored in `:persistent_term` keyed by its SHA-256. Every cell then SHARES that one struct
  with no per-read copy (this is what `persistent_term` gives that ETS does not) — so instantiating the
  Nth cell of a program costs only its fresh mutable state (memory + counters), never re-decoding the
  9.6 MB coreutils module. Assumes a low-cardinality module set (the fleet's compilers/programs); each
  `put` does a global scan, amortized over many reads.
  """
  def decode_cached(bytes) when is_binary(bytes) do
    hash = :crypto.hash(:sha256, bytes)
    key = {:washy_mod_cache, hash}

    case :persistent_term.get(key, nil) do
      nil ->
        case decode(bytes) do
          # stamp the content hash as a stable id so tier_cached keys its build cache in O(1)
          {:ok, mod} -> mod = %{mod | id: hash}; :persistent_term.put(key, mod); {:ok, mod}
          err -> err
        end

      mod ->
        {:ok, mod}
    end
  end

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

  # 13 = tag: vec of tags (attribute byte + typeidx) — exception tags for the EH proposal (WASIX §0).
  defp section(13, content, mod) do
    {tags, _} = vec(content, fn <<_attr, r::binary>> -> uleb(r) end)
    %{mod | tags: tags}
  end

  # 4 = table: vec of table types (reftype byte + limits). We keep the first table's {min, max} so
  # table.size/grow know the declared size (WASIX §0). One-table model, matching call_indirect.
  defp section(4, content, mod) do
    {tables, _} = vec(content, fn <<_reftype, r::binary>> -> limits(r) end)
    %{mod | table_type: List.first(tables)}
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

  # Exception handling (exnref proposal, WASIX §0): try_table is a block carrying catch clauses;
  # throw raises a tag's exception; throw_ref re-raises a caught exnref.
  defp parse_op(0x1F, rest) do
    {_bt, r} = blocktype(rest)
    {catches, r} = vec(r, &catch_clause/1)
    {body, :end, r} = parse_instrs(r)
    {{:try_table, catches, body}, r}
  end

  defp parse_op(0x08, rest), do: ({t, r} = uleb(rest); {{:throw, t}, r})
  defp parse_op(0x0A, rest), do: {{:throw_ref}, rest}

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
      8 -> {data, r} = uleb(rest); <<_mem, r::binary>> = r; {{:memory_init, data}, r}
      9 -> {_data, r} = uleb(rest); {{:data_drop}, r}
      10 -> <<_dst, _src, r::binary>> = rest; {{:memory_copy}, r}
      11 -> <<_mem, r::binary>> = rest; {{:memory_fill}, r}
      n when n in 0..7 -> {{:trunc_sat, n}, rest}
      # table ops (reference-types proposal): init/elem.drop/copy carry table/elem indices; grow/size/fill a tableidx.
      12 -> {_elem, r} = uleb(rest); {_tbl, r} = uleb(r); {{:table_init}, r}
      13 -> {_elem, r} = uleb(rest); {{:elem_drop}, r}
      14 -> {_dt, r} = uleb(rest); {_st, r} = uleb(r); {{:table_copy}, r}
      15 -> {_t, r} = uleb(rest); {{:table_grow}, r}
      16 -> {_t, r} = uleb(rest); {{:table_size}, r}
      17 -> {_t, r} = uleb(rest); {{:table_fill}, r}
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

  # 0xFE = the ATOMICS / threads prefix (WASIX §0). Sub-opcode is a uleb; loads/stores/rmw/wait/notify
  # carry a memarg, atomic.fence carries a single (reserved) byte. We parse into typed tuples the
  # interpreter executes — atomicity-under-contention lands with threads (§2); single-thread semantics here.
  defp parse_op(0xFE, rest) do
    {sub, rest} = uleb(rest)

    cond do
      sub == 0x03 -> (<<_reserved, r::binary>> = rest; {{:atomic_fence}, r})
      sub == 0x00 -> ({o, r} = memarg(rest); {{:atomic_notify, o}, r})
      sub == 0x01 -> ({o, r} = memarg(rest); {{:atomic_wait, 4, o}, r})
      sub == 0x02 -> ({o, r} = memarg(rest); {{:atomic_wait, 8, o}, r})
      sub in 0x10..0x16 -> ({o, r} = memarg(rest); {{:atomic_load, o, atomic_load_width(sub)}, r})
      sub in 0x17..0x1D -> ({o, r} = memarg(rest); {{:atomic_store, o, atomic_store_width(sub)}, r})
      sub in 0x1E..0x4E -> ({o, r} = memarg(rest); {opname, n} = atomic_rmw_shape(sub); {{:atomic_rmw, opname, o, n}, r})
      true -> raise("washy: unimplemented 0xFE sub-op #{sub}")
    end
  end

  # Access widths (bytes) for the atomic load (0x10..0x16) and store (0x17..0x1D) sub-opcodes.
  defp atomic_load_width(s), do: elem({4, 8, 1, 2, 1, 2, 4}, s - 0x10)
  defp atomic_store_width(s), do: elem({4, 8, 1, 2, 1, 2, 4}, s - 0x17)

  # The 49 rmw sub-opcodes (0x1E..0x4E) = 7 ops × 7 widths. op = base/7, width = base rem 7.
  defp atomic_rmw_shape(sub) do
    base = sub - 0x1E
    op = elem({:add, :sub, :and, :or, :xor, :xchg, :cmpxchg}, div(base, 7))
    n = elem({4, 8, 1, 2, 1, 2, 4}, rem(base, 7))
    {op, n}
  end

  # The n-byte unsigned mask, and the rmw operation applied to (old, operand), wrapped to the width.
  defp mask_n(n), do: (1 <<< (n * 8)) - 1
  defp atomic_apply(:add, old, v, n), do: (old + v) &&& mask_n(n)
  defp atomic_apply(:sub, old, v, n), do: (old - v) &&& mask_n(n)
  defp atomic_apply(:and, old, v, n), do: (old &&& v) &&& mask_n(n)
  defp atomic_apply(:or, old, v, n), do: (old ||| v) &&& mask_n(n)
  defp atomic_apply(:xor, old, v, n), do: bxor(old, v) &&& mask_n(n)
  defp atomic_apply(:xchg, _old, v, n), do: v &&& mask_n(n)

  # Reference types (WASIX §0): a funcref is the function index (an integer); a null ref is `:null`.
  # ref.null carries a heaptype byte; ref.func a funcidx; table.get/set a tableidx (single-table model).
  defp parse_op(0xD0, <<_heaptype, rest::binary>>), do: {{:ref_null}, rest}
  defp parse_op(0xD1, rest), do: {{:ref_is_null}, rest}
  defp parse_op(0xD2, rest), do: ({i, r} = uleb(rest); {{:ref_func, i}, r})
  defp parse_op(0x25, rest), do: ({_t, r} = uleb(rest); {{:table_get}, r})
  defp parse_op(0x26, rest), do: ({_t, r} = uleb(rest); {{:table_set}, r})

  # the pure numeric/compare/convert ops (no immediate) — a contiguous range; dispatch by opcode
  defp parse_op(op, rest) when op == 0x1B or (op >= 0x45 and op <= 0xC4), do: {{:op, op}, rest}
  # anything else carries an immediate we haven't taught the parser — fail LOUDLY with the exact opcode
  defp parse_op(op, _rest), do: raise("washy parser: unhandled opcode 0x#{Integer.to_string(op, 16)} (needs an immediate-aware clause)")

  # blocktype is one byte for the common cases (0x40 empty / a valtype); we don't need its value to run.
  defp blocktype(<<_b, rest::binary>>), do: {nil, rest}

  # A try_table catch clause: catch (tag→label), catch_ref (tag→label, +exnref), catch_all (→label),
  # catch_all_ref (→label, +exnref). The label is a br target relative to the try_table frame.
  defp catch_clause(<<0x00, rest::binary>>), do: ({t, r} = uleb(rest); {l, r} = uleb(r); {{:catch, t, l}, r})
  defp catch_clause(<<0x01, rest::binary>>), do: ({t, r} = uleb(rest); {l, r} = uleb(r); {{:catch_ref, t, l}, r})
  defp catch_clause(<<0x02, rest::binary>>), do: ({l, r} = uleb(rest); {{:catch_all, l}, r})
  defp catch_clause(<<0x03, rest::binary>>), do: ({l, r} = uleb(rest); {{:catch_all_ref, l}, r})

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
  # Default instruction FUEL: a generous-but-FINITE work budget so a runaway guest traps
  # (`:out_of_fuel`) instead of spinning forever. Wall-clock is bounded separately by
  # `Nexus.Washy.Sandbox`. Override per run with `call(mod, name, args, fuel: N)`.
  @default_fuel 2_000_000_000
  # Max wasm CALL depth (recursive calls grow the BEAM process stack). Bounds it to a clean
  # `:stack_exhausted` trap instead of an opaque process crash. Block/loop nesting is statically
  # finite and not counted here.
  @default_max_depth 10_000
  # Hard ceiling on memory growth (pages) — replaces the old implicit 64-page cap. A guest cannot
  # grow past this, so `memory.grow` can never OOM the host. 4096 pages = 256 MB. Override per run.
  @default_max_pages 4096

  def call(%__MODULE__{} = mod, name, args, opts \\ []) when is_list(args) do
    {result, _io} = call_io(mod, name, args, opts)
    result
  end

  @doc """
  Like `call/4`, but also returns captured stdout (what the guest wrote via WASI `fd_write`).
  Opts: `:fuel` (instruction budget, default #{@default_fuel}).
  """
  def call_io(%__MODULE__{} = mod, name, args, opts \\ []) when is_list(args) do
    # Snapshot ALL per-run process-dict context so a NESTED call_io (host_exec's fork/exec emulation)
    # restores the outer run's context on return. The interpreter threads `rt` and is immune, but
    # TRANSPILED code reads these from the dict — without restore, an outer transpiled function running
    # after a host_exec would see the INNER program's globals/table/mem_pages/fuel (the wb-6c2y bug:
    # shell strspn read coreutils' stack pointer against the shell's smaller memory → OOB trap).
    prev = Process.get(:washy_out)
    prev_mem = Process.get(:washy_mem)
    prev_globals = Process.get(:washy_globals)
    prev_table = Process.get(:washy_table)
    prev_mem_pages = Process.get(:washy_mem_pages)
    prev_max_pages = Process.get(:washy_max_pages)
    prev_fuel = Process.get(:washy_last_fuel)
    Process.put(:washy_out, [])
    globals = new_globals(mod.globals)
    mem_pages = new_mem(mod.mem)
    init_data(globals, mod.data)
    fuel = :atomics.new(1, signed: true)
    budget = Keyword.get(opts, :fuel, @default_fuel)
    :atomics.put(fuel, 1, budget)
    # expose the fuel counter so the caller can compute consumed = budget - remaining (metrics)
    Process.put(:washy_last_fuel, {budget, fuel})
    depth = :atomics.new(1, signed: true)
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    max_pages = Keyword.get(opts, :max_pages, @default_max_pages)
    table = new_table(mod.elements, globals)
    # Expose the runtime context via the process dict (alongside :washy_mem) so TRANSPILED standalone
    # BEAM code can reach the same globals/table/mem_pages/fuel the interpreter holds in `rt` — what the
    # transpiler needs for global.get/set, call_indirect, memory.grow/bounds, and fuel-charging.
    Process.put(:washy_globals, globals)
    Process.put(:washy_table, table)
    Process.delete(:washy_table_size)
    Process.put(:washy_mem_pages, mem_pages)
    Process.put(:washy_max_pages, max_pages)
    # TIERED lane (opt-in), LAZY hot-path model: start fully interpreted (zero upfront cost), count
    # calls, and compile ONLY functions that get hot (threshold crossings) — so even a 5000-function
    # module pays nothing at startup and compiles just its working set. The growing native registry lives
    # in the mutable `:washy_jit` dict; call counts in a per-run `:counters`.
    prev_jit = Process.get(:washy_jit)

    lazy =
      if Keyword.get(opts, :transpile, false) do
        Process.put(:washy_jit, %{})
        counts = :counters.new(max(1, length(mod.code)), [:write_concurrency])
        # :async (default) compiles hot functions in the BACKGROUND so a run never stalls on a compile
        # storm; :sync compiles inline (deterministic — tests, and where blocking is acceptable).
        {counts, Keyword.get(opts, :tier_threshold, 20), Keyword.get(opts, :tier_async, true)}
      else
        nil
      end

    rt = %{mod: mod, mem_pages: mem_pages, globals: globals, table: table, fuel: fuel, depth: depth, max_depth: max_depth, max_pages: max_pages, lazy: lazy, ni: length(mod.imports)}
    # stash rt so a transpiled function can trampoline back into the interpreter (`call_local`)
    prev_rt = Process.get(:washy_rt)
    Process.put(:washy_rt, rt)

    try do
      result = call_fn(rt, Map.fetch!(mod.exports, name), args)
      out = Process.get(:washy_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
      # :washy_out/:washy_mem are restored only on the NORMAL return: when the guest throws (proc_exit /
      # trap) the immediate caller (host_exec) still reads the partial output + the guest's memory before
      # IT restores them, so we must leave those in place on the throw path.
      restore(:washy_out, prev)
      restore(:washy_mem, prev_mem)
      {result, out}
    after
      # The EXECUTION CONTEXT (globals/table/mem_pages/fuel/rt) must be restored on EVERY exit — normal OR
      # throw — or an outer TRANSPILED function resuming after a host_exec would read the inner program's
      # context from the dict (the wb-6c2y OOB: shell read coreutils' SP/page-count). No caller reads
      # these post-throw, so restoring them in `after` is safe.
      restore(:washy_globals, prev_globals)
      restore(:washy_table, prev_table)
      restore(:washy_mem_pages, prev_mem_pages)
      restore(:washy_max_pages, prev_max_pages)
      restore(:washy_last_fuel, prev_fuel)
      restore(:washy_rt, prev_rt)
      restore(:washy_jit, prev_jit)
    end
  end

  # ── PERSISTENT INSTANCES (wb: JS guest-actor state across messages) ─────────────────────────────
  #
  # `call_io` is one-shot: set up the process-dict run context (`:washy_mem`/globals/table/fuel/`:washy_rt`),
  # invoke ONE function, restore on exit. A persistent guest needs the OPPOSITE of the restore: instantiate
  # + run a setup function (`_start`) but KEEP the linear memory + runtime state, then re-enter a named
  # export per message with that SAME memory/globals alive — so QuickJS's heap (its `let count=0`, closures)
  # survives between deliveries instead of resetting on every script re-run.
  #
  # OWNERSHIP MODEL — single-process, no shared mutable memory. An `Instance` is OWNED by exactly one BEAM
  # process (the actor GenServer). The struct is the *canonical, immutable snapshot* of the guest's run
  # context (the `:atomics` refs for memory/globals/table/fuel, the page-count atomics, the decoded module,
  # the import count). `:atomics` refs are shared handles to off-heap mutable cells, but only the owning
  # process ever installs them into ITS process dict and invokes the export — there is no cross-process
  # access, so there is no shared-mutable hazard. `instance_invoke` runs the export IN THE CALLING
  # (owner) process directly (NOT in a `Sandbox` Task): re-spawning a Task per message would lose the
  # process-dict run context (the Task gets a fresh dict), and copying every atomics ref + re-pinning it
  # each call buys nothing — the owner process already provides BEAM isolation (one actor = one process =
  # its own heap; a trap is a caught exception). Wall-clock bounding for a delivery is the GenServer's
  # concern (it can run the invoke under its own timeout); fuel is bounded per-call here.
  #
  # `memory.grow` REALLOCATES `:washy_mem` (atomics can't grow in place) and stores the new backing in the
  # dict. So after an invoke we SNAPSHOT the (possibly swapped) `:washy_mem` back into the returned handle.
  # `mem_pages`/globals/table/fuel are stable atomics refs (mutated in place), so they never need re-capture
  # — but we re-read them defensively. Hence `instance_invoke/4` returns `{result, out, new_instance}`: the
  # owner threads the updated handle forward (it differs from the input only if memory grew).

  @typedoc """
  An opaque persistent-guest handle. Captures everything `call_io` would have torn down, so the export
  can be re-entered with the guest's memory/globals/rt still live. Owned by one process; thread the
  `new_instance` returned by `instance_invoke/3` forward.
  """
  @type instance :: %{
          __struct__: __MODULE__.Instance,
          mod: t(),
          mem: reference() | nil,
          mem_pages: reference() | nil,
          max_pages: pos_integer(),
          globals: reference() | nil,
          table: map(),
          rt: map()
        }

  defmodule Instance do
    @moduledoc "Opaque persistent-guest handle (see `Nexus.Washy.instance_*`). Hold it in the owner process."
    defstruct [:mod, :mem, :mem_pages, :max_pages, :globals, :table, :rt, vfs: %{}]
  end

  @doc """
  **Instantiate a guest and KEEP it alive.** Runs setup `name` (e.g. `"_start"` — which for a JS guest
  evals the script, registering `Beam.onMessage`) to completion, then captures the live run context
  (memory/globals/table/fuel/rt) into an `%Instance{}` instead of tearing it down. Returns
  `{:ok, instance, out}` (setup's captured stdout) or `{:exit, code, out}` (setup called `proc_exit`)
  or `{:trap, reason}`.

  Like `call_io`, this snapshots and restores the CALLER's prior process-dict context around the setup
  run, so it is safe to call from inside another run (and leaves the caller's dict untouched). The
  RETURNED instance is the only live reference to the guest's state.
  """
  def instance_start(%__MODULE__{} = mod, name \\ "_start", args \\ [], opts \\ []) when is_list(args) do
    prev = capture_run_ctx()

    globals = new_globals(mod.globals)
    mem_pages = new_mem(mod.mem)
    init_data(globals, mod.data)
    fuel = :atomics.new(1, signed: true)
    :atomics.put(fuel, 1, Keyword.get(opts, :fuel, @default_fuel))
    Process.put(:washy_last_fuel, {Keyword.get(opts, :fuel, @default_fuel), fuel})
    depth = :atomics.new(1, signed: true)
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    max_pages = Keyword.get(opts, :max_pages, @default_max_pages)
    table = new_table(mod.elements, globals)
    Process.put(:washy_out, [])
    Process.put(:washy_globals, globals)
    Process.put(:washy_table, table)
    Process.delete(:washy_table_size)
    Process.put(:washy_mem_pages, mem_pages)
    Process.put(:washy_max_pages, max_pages)

    rt = %{mod: mod, mem_pages: mem_pages, globals: globals, table: table, fuel: fuel, depth: depth, max_depth: max_depth, max_pages: max_pages, lazy: nil, ni: length(mod.imports)}
    Process.put(:washy_rt, rt)

    try do
      _ = call_fn(rt, Map.fetch!(mod.exports, name), args)
      out = Process.get(:washy_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
      # capture the (possibly grown) memory backing into the handle
      inst = %Instance{
        mod: mod, mem: Process.get(:washy_mem), mem_pages: mem_pages, max_pages: max_pages,
        globals: globals, table: Process.get(:washy_table, table), rt: rt,
        # carry the guest VFS (:map backend) so files written during one re-entry persist into the next
        vfs: Process.get(:washy_vfs, %{})
      }
      {:ok, inst, out}
    catch
      :throw, {:washy_exit, code} ->
        out = Process.get(:washy_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
        {:exit, code, out}
    rescue
      e in Nexus.Washy.Trap -> {:trap, e.reason}
    after
      restore_run_ctx(prev)
    end
  end

  @doc """
  **Re-enter a live guest.** Invoke export `name` (e.g. `"wb_dispatch"`) on `instance`, reusing its
  memory/globals/table/rt — so guest state set up by `instance_start` (and prior invokes) is still there.
  Each call runs to completion with its OWN fresh fuel budget (`:fuel` opt). Returns
  `{:ok, result, out, new_instance}` / `{:exit, code, out, new_instance}` / `{:trap, reason, new_instance}`.

  Always thread `new_instance` forward: if the guest grew memory, its `:washy_mem` backing was swapped and
  the new backing is captured into `new_instance.mem` (the input handle's `mem` is now stale).

  Run this IN THE OWNER PROCESS (the GenServer). It installs the held context into the process dict,
  invokes, snapshots back, and restores the caller's prior dict context in `after` — so a nested invoke
  (or any other run in the same process) is unaffected.
  """
  def instance_invoke(%Instance{} = inst, name, args \\ [], opts \\ []) when is_list(args) do
    prev = capture_run_ctx()

    # fresh fuel + depth per delivery; everything else is the held (mutated-in-place / re-captured) state
    fuel = :atomics.new(1, signed: true)
    :atomics.put(fuel, 1, Keyword.get(opts, :fuel, @default_fuel))
    depth = :atomics.new(1, signed: true)
    rt = %{inst.rt | fuel: fuel, depth: depth}

    Process.put(:washy_out, [])
    Process.put(:washy_mem, inst.mem)
    Process.put(:washy_globals, inst.globals)
    Process.put(:washy_table, inst.table)
    Process.delete(:washy_table_size)
    Process.put(:washy_mem_pages, inst.mem_pages)
    Process.put(:washy_max_pages, inst.max_pages)
    # restore the guest VFS so reads see files written by earlier messages (overrides any per-run reset)
    Process.put(:washy_vfs, inst.vfs || %{})
    Process.put(:washy_last_fuel, {Keyword.get(opts, :fuel, @default_fuel), fuel})
    Process.put(:washy_rt, rt)

    try do
      result = call_fn(rt, Map.fetch!(inst.mod.exports, name), args)
      out = Process.get(:washy_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
      {:ok, result, out, snapshot(inst, rt)}
    catch
      :throw, {:washy_exit, code} ->
        out = Process.get(:washy_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
        {:exit, code, out, snapshot(inst, rt)}
    rescue
      e in Nexus.Washy.Trap -> {:trap, e.reason, snapshot(inst, rt)}
    after
      restore_run_ctx(prev)
    end
  end

  @doc """
  **Free a persistent instance.** The guest's state lives in `:atomics` (off-heap) + the immutable struct;
  there is no native resource to release, so freeing = dropping the references so the GC reclaims the
  atomics. Returns `:ok`. (Explicit so the actor's `terminate` has a clear, intentional teardown point and
  so the API reads symmetrically with `instance_start`.)
  """
  def instance_free(%Instance{}), do: :ok

  @doc """
  **Clone a booted instance** (wb-8mdz.4). Produces a fresh, independent instance with a byte-identical
  copy of the template's linear memory (the whole QuickJS world: heap, the static `g_ctx`, everything) +
  copied globals, sharing the immutable table/vfs maps (Elixir COW). The actor layer boots ONE template
  (QuickJS + the full prelude) once, then clones it per guest and `wb_eval`s just the per-actor script —
  skipping the multi-second prelude re-eval on every spawn. Pure Elixir; no native, no NIF.
  """
  def instance_clone(%Instance{} = t) do
    msize = :atomics.info(t.mem).size
    newmem = :atomics.new(msize, signed: false)
    copy_atomics(t.mem, newmem, msize)

    newpages = :atomics.new(1, signed: false)
    :atomics.put(newpages, 1, :atomics.get(t.mem_pages, 1))

    newglobals = clone_globals(t.globals)
    rt = %{t.rt | mem_pages: newpages, globals: newglobals}
    %Instance{t | mem: newmem, mem_pages: newpages, globals: newglobals, rt: rt}
  end

  defp copy_atomics(src, dst, n), do: for(i <- 1..n//1, do: :atomics.put(dst, i, :atomics.get(src, i)))
  defp clone_globals(nil), do: nil

  defp clone_globals(g) do
    n = :atomics.info(g).size
    ng = :atomics.new(n, signed: false)
    copy_atomics(g, ng, n)
    ng
  end

  # snapshot mutated run state back into the handle. Only `:washy_mem` (reallocated by memory.grow) and the
  # table can change identity per invoke; globals/mem_pages are atomics mutated in place (same ref).
  defp snapshot(%Instance{} = inst, rt) do
    %{
      inst
      | mem: Process.get(:washy_mem),
        table: Process.get(:washy_table, inst.table),
        vfs: Process.get(:washy_vfs, inst.vfs),
        rt: %{rt | fuel: nil, depth: nil}
    }
  end

  # capture / restore the full per-run process-dict context (same keys call_io guards) so instance ops are
  # nesting-safe — a setup/invoke that runs inside another washy run leaves the outer run's dict intact.
  defp capture_run_ctx do
    %{
      out: Process.get(:washy_out), mem: Process.get(:washy_mem), globals: Process.get(:washy_globals),
      table: Process.get(:washy_table), mem_pages: Process.get(:washy_mem_pages),
      max_pages: Process.get(:washy_max_pages), last_fuel: Process.get(:washy_last_fuel),
      rt: Process.get(:washy_rt)
    }
  end

  defp restore_run_ctx(c) do
    restore(:washy_out, c.out)
    restore(:washy_mem, c.mem)
    restore(:washy_globals, c.globals)
    restore(:washy_table, c.table)
    restore(:washy_mem_pages, c.mem_pages)
    restore(:washy_max_pages, c.max_pages)
    restore(:washy_last_fuel, c.last_fuel)
    restore(:washy_rt, c.rt)
  end

  @doc """
  **Host-mediated invocation — the thesis's fork/exec emulation.** A running guest (e.g. a shell)
  invokes another program: `argv[0]` resolves to a wasm module (via the `:washy_programs` registry,
  with a multicall `:default` fallback like coreutils), which Washy runs NESTED with the given
  `stdin` and `argv`, returning `{stdout, exit_code}`. Cooperative + buffered — no real concurrency,
  no real fork; the guest only needs to BELIEVE it spawned a process.

  The child gets a FRESH fd table + argv/stdin and its own isolated linear memory (call_io allocates
  it); it SHARES the parent's virtual FS so file effects persist across the "pipeline". The parent's
  full context (captured stdout, memory, argv, stdin, fds) is saved and restored around the call —
  nesting-safe because the BEAM handles the re-entrant call_io for free.
  """
  def host_exec([prog | _] = argv, stdin, opts \\ []) when is_binary(stdin) do
    case resolve_program(prog) do
      nil ->
        {"", 127}

      mod ->
        saved =
          {Process.get(:washy_out), Process.get(:washy_mem), Process.get(:washy_argv),
           Process.get(:washy_stdin), Process.get(:washy_fds), Process.get(:washy_nextfd)}

        Process.put(:washy_out, [])
        Process.put(:washy_argv, argv)
        Process.put(:washy_stdin, stdin)
        Process.put(:washy_fds, %{})
        Process.put(:washy_nextfd, 4)

        # If the PARENT run is tiering, the nested program tiers too — so a pipeline's actual compute
        # (the grep/sort/sha256 in coreutils) runs native, not just the shell. Hot functions compile in
        # the background + cache across invocations, so repeated/heavy commands get fast.
        child_opts =
          case Process.get(:washy_rt) do
            %{lazy: {_, _, _}} -> Keyword.put_new(opts, :transpile, true)
            _ -> opts
          end

        try do
          try do
            {_r, out} = call_io(mod, "_start", [], child_opts)
            {out, 0}
          rescue
            # a child that TRAPS (e.g. a Rust panic → unreachable when it touches outside its sandbox)
            # must not crash the parent — return its partial output + a non-zero exit code.
            _ -> {Process.get(:washy_out, []) |> Enum.reverse() |> IO.iodata_to_binary(), 134}
          catch
            :throw, {:washy_exit, code} ->
              {Process.get(:washy_out, []) |> Enum.reverse() |> IO.iodata_to_binary(), code}
          end
        after
          {o, m, a, s, f, n} = saved
          restore(:washy_out, o)
          restore(:washy_mem, m)
          restore(:washy_argv, a)
          restore(:washy_stdin, s)
          restore(:washy_fds, f)
          restore(:washy_nextfd, n)
        end
    end
  end

  defp restore(key, nil), do: Process.delete(key)
  defp restore(key, val), do: Process.put(key, val)

  @doc """
  Invoke a HOST IMPORT by its decoded spec (`{module, name, type_idx}`) with `args` — the seam the
  **transpiler** uses to perform WASI/host I/O from compiled BEAM code. It dispatches to the exact same
  `call_host` the interpreter uses, so a transpiled guest and an interpreted guest do identical I/O.
  Host functions read/write guest memory via the process-dict `:washy_mem` (set up by the run), not
  `rt` — so a `nil` runtime is fine here. proc_exit still throws `{:washy_exit, code}`; the caller catches.
  """
  def invoke_host({_module, _name, _type} = spec, args) when is_list(args), do: call_host(nil, spec, args)

  @doc """
  **Trampoline from transpiled code back into the interpreter.** A native (transpiled) function calls
  this for a callee that was NOT transpiled (interpreted lane), passing the global func index + arg
  list. It dispatches through the same `call_fn` the interpreter uses (host import → `call_host`, local
  → `invoke`, which may itself re-dispatch to native), all on the shared run state held in `:washy_rt`.
  """
  def call_local(fidx, args) when is_integer(fidx) and is_list(args) do
    case Process.get(:washy_rt) do
      nil -> raise "call_local/2 outside a washy run (no :washy_rt)"
      rt -> call_fn(rt, fidx, args)
    end
  end

  @doc """
  **Indirect call from transpiled code on the shared run state.** Mirrors the interpreter's
  `{:call_indirect, typeidx}` step EXACTLY: resolve the table index → global func index (trap
  `:undefined_element` if absent), check the resolved func's type against the expected signature at
  `typeidx` (trap `:indirect_call_type_mismatch` on mismatch), then dispatch through the same `call_fn`
  on the shared `:washy_rt`. Returns the callee result (or `nil` for a void target).
  """
  def call_indirect_dyn(table_idx, typeidx, args)
      when is_integer(table_idx) and is_integer(typeidx) and is_list(args) do
    case Process.get(:washy_rt) do
      nil ->
        raise "call_indirect_dyn/3 outside a washy run (no :washy_rt)"

      rt ->
        f = Map.get(rt.table, table_idx)
        if f == nil, do: trap!(:undefined_element)
        expected = Enum.at(rt.mod.types, typeidx)
        if func_type(rt.mod, f) != expected, do: trap!(:indirect_call_type_mismatch)
        call_fn(rt, f, args)
    end
  end

  @doc "Build a module's mutable globals array (the transpiler installs this in `:washy_globals`)."
  def init_globals(%__MODULE__{} = mod), do: new_globals(mod.globals)

  @doc """
  Charge one unit of fuel (the transpiler calls this on each loop back-edge so a transpiled loop can't
  spin unbounded). Raises the SAME `:out_of_fuel` trap the interpreter does when the budget is spent.
  Coarser than the interpreter's per-instruction charge (per-iteration here), but it bounds runaway loops.
  """
  def charge_fuel do
    case Process.get(:washy_last_fuel) do
      {_budget, fuel} -> if :atomics.sub_get(fuel, 1, 1) < 0, do: trap!(:out_of_fuel)
      _ -> :ok
    end
  end

  # argv[0] → a wasm module: an explicit program, else a multicall `:default` (e.g. coreutils) that
  # dispatches on argv[0]. nil = command not found.
  defp resolve_program(name) do
    progs = Process.get(:washy_programs, %{})
    Map.get(progs, name) || Map.get(progs, :default)
  end

  # Linear memory is PACKED + RIGHT-SIZED for density: the backing `:atomics` is sized to the module's
  # `min` pages (NOT a 64-page cap) with 8 bytes per slot, and lives in the process dict (`:washy_mem`)
  # so `memory.grow` can REALLOCATE it (atomics can't grow in place) and every reader sees the new
  # backing. One guest = one process, so the dict is the right mutable cell. `mem_pages` (logical page
  # count) is a stable 1-slot atomics. `wmem/0` is the current backing.
  @page_words 8192
  defp wmem, do: Process.get(:washy_mem)

  defp new_mem(nil), do: (Process.delete(:washy_mem); nil)

  defp new_mem({min, _max}) do
    pages = max(1, min)
    Process.put(:washy_mem, :atomics.new(pages * @page_words, signed: false))
    pref = :atomics.new(1, signed: false)
    :atomics.put(pref, 1, pages)
    pref
  end

  @doc """
  `memory.grow(n)` for TRANSPILED code — mirrors the interpreter's grow exactly: realloc `:washy_mem`
  to `old+n` pages (copying live words), bump the `:washy_mem_pages` count, return the OLD page count;
  or `-1` (masked to i32) when `n<0` or the new size exceeds the run's `:washy_max_pages` ceiling. Reads
  all state from the process dict (the shared run context), so a transpiled and an interpreted grow are
  identical. Transpiled load/store re-read `:washy_mem` per access, so they see the grown backing.
  """
  def guest_memory_grow(n) do
    mem_pages = Process.get(:washy_mem_pages)
    old = :atomics.get(mem_pages, 1)
    new = old + n

    if n >= 0 and new <= Process.get(:washy_max_pages, @default_max_pages) do
      oldmem = wmem()
      newmem = :atomics.new(new * @page_words, signed: false)
      for i <- 1..(old * @page_words)//1, do: :atomics.put(newmem, i, :atomics.get(oldmem, i))
      Process.put(:washy_mem, newmem)
      :atomics.put(mem_pages, 1, new)
      old
    else
      -1 &&& @mask32
    end
  end

  # IEEE-754 float arithmetic for TRANSPILED code (wb-8mdz.3) — the SAME farith the interpreter uses, so a
  # transpiled f32/f64 add/sub/mul/div by zero / overflow / on a non-finite operand yields ±Inf/NaN instead
  # of raising ArithmeticError. `op` ∈ :add|:sub|:mul|:div, `size` ∈ 32|64. Oracle-green by construction
  # (asm call_exts the identical function the interp calls).
  def guest_farith(a, b, op, size), do: farith(a, b, op, size)

  @doc "IEEE float comparison for transpiled code — 0/1, NaN-unordered, identical to the interp's fcmp."
  def guest_fcmp(a, b, op), do: if(fcmp(a, b, op), do: 1, else: 0)

  @doc "IEEE float min/max/abs/neg/sqrt for transpiled code — non-finite-safe, identical to the interp."
  def guest_fminmax(a, b, which, size), do: fminmax(a, b, which, size)
  def guest_fabs(a, size), do: fabs(a, size)
  def guest_fneg(a, size), do: fneg(a, size)
  def guest_fsqrt(a, size), do: fsqrt(a, size)

  @doc "IEEE float ceil/floor/trunc/nearest/copysign for transpiled code — non-finite-safe, == the interp."
  def guest_fceil(a, size), do: fround_unary(a, size, &Float.ceil/1)
  def guest_ffloor(a, size), do: fround_unary(a, size, &Float.floor/1)
  def guest_ftrunc(a, size), do: fround_unary(a, size, fn x -> trunc(x) * 1.0 end)
  def guest_fnearest(a, size), do: fround_unary(a, size, &fnearest/1)
  def guest_fcopysign(a, b, size), do: fcopysign_nf(a, b, size)

  @doc "sign-extension ops for transpiled code (i32/i64.extend8_s/16_s/32_s) — identical to the interp."
  def guest_i32_extend8_s(a), do: sext(a &&& 0xFF, 8)
  def guest_i32_extend16_s(a), do: sext(a &&& 0xFFFF, 16)
  def guest_i64_extend8_s(a), do: sext64(a &&& 0xFF, 8)
  def guest_i64_extend16_s(a), do: sext64(a &&& 0xFFFF, 16)
  def guest_i64_extend32_s(a), do: sext64(a &&& @mask32, 32)

  @doc "exnref throw/throw_ref for transpiled code — same {:wasm_exc,…} Elixir-throw the interp uses, so a
  try_table (interp or asm) catches it identically and an uncaught one propagates out of the function."
  def guest_throw(tagidx, vals), do: throw({:wasm_exc, tagidx, vals})
  def guest_throw_ref({:exnref, tag, vals}), do: throw({:wasm_exc, tag, vals})
  def guest_throw_ref(:null), do: trap!(:null_exnref)
  def guest_throw_ref(_), do: trap!(:not_an_exnref)

  @doc "tag arity (operand count a `throw` consumes), from the module's tag→type table — for the asm lane."
  def tag_arity_of(mod, tagidx) do
    typeidx = Enum.at(mod.tags, tagidx)
    {params, _results} = Enum.at(mod.types, typeidx)
    length(params)
  end

  # ── try_table (catch side) helpers for the asm lane — mirror the interp's match_catch/handle_catch.
  # A try_table's BEAM `try_case` hands us {class, reason}; only a wasm exception ({:throw, {:wasm_exc,…}})
  # is ours to dispatch — anything else (a host error/exit) is re-raised so it propagates identically.
  @doc "Decode a caught BEAM throw into `{:exc, tag, vals}` when it's a wasm exception, else `:rethrow`."
  def guest_catch_match(:throw, {:wasm_exc, tag, vals}), do: {:exc, tag, vals}
  def guest_catch_match(_class, _reason), do: :rethrow

  @doc "Re-raise a non-matching/non-wasm exception with its original class + captured stacktrace."
  def guest_reraise(class, reason, stacktrace), do: :erlang.raise(class, reason, stacktrace)

  @doc "Build an exnref term `{:exnref, tag, vals}` for a `catch_ref`/`catch_all_ref` clause."
  def guest_mk_exnref(tag, vals), do: {:exnref, tag, vals}

  # ── reftypes / table ops for TRANSPILED code (WASIX §0) — bit-identical mirrors of the interpreter's
  # step({:ref_*}/{:table_*}) handlers, reading the shared run state (:washy_rt / :washy_table). The asm
  # lane call_exts these so table/ref ops run NATIVE instead of falling back to the interpreter. ──
  @doc "`ref.is_null` for transpiled code — 1 if the popped ref is the null sentinel, else 0."
  def guest_ref_is_null(:null), do: 1
  def guest_ref_is_null(_), do: 0

  @doc "`table.get(i)` — the table entry at `i` (global func index / ref), or the null sentinel."
  def guest_table_get(i) do
    rt = Process.get(:washy_rt)
    Map.get(Process.get(:washy_table, rt.table), i, :null)
  end

  @doc "`table.set(i, v)` — store ref `v` at index `i` in the mutable table. Returns :ok."
  def guest_table_set(i, v) do
    rt = Process.get(:washy_rt)
    Process.put(:washy_table, Map.put(Process.get(:washy_table, rt.table), i, v))
    :ok
  end

  @doc "`table.size` — current table length."
  def guest_table_size, do: table_size(Process.get(:washy_rt))

  @doc "`table.grow(init, n)` — append `n` slots of `init`; returns old size, or -1 (u32) past the max."
  def guest_table_grow(init, n) do
    rt = Process.get(:washy_rt)
    old = table_size(rt)
    new = old + n
    max = case rt.mod.table_type do {_, m} -> m; _ -> nil end

    if max != nil and new > max do
      -1 &&& @mask32
    else
      table = Enum.reduce(grow_range(old, new), Process.get(:washy_table, rt.table), fn idx, t -> Map.put(t, idx, init) end)
      Process.put(:washy_table, table)
      Process.put(:washy_table_size, new)
      old
    end
  end

  @doc "`table.fill(i, val, n)` — set `n` slots from `i` to ref `val`. Returns :ok."
  def guest_table_fill(i, val, n) do
    rt = Process.get(:washy_rt)
    table = Enum.reduce(grow_range(i, i + n), Process.get(:washy_table, rt.table), fn idx, t -> Map.put(t, idx, val) end)
    Process.put(:washy_table, table)
    Process.delete(:washy_table_size)
    :ok
  end

  @doc "`memory.copy(dst, src, n)` for transpiled code — mirrors the interpreter (overlap-safe, bounds-trapped)."
  def guest_memory_copy(dst, src, n) do
    if n > 0 do
      mem = wmem()
      bounds_g!(dst, n)
      bounds_g!(src, n)
      mem_copy(mem, dst, src, n)
    end

    :ok
  end

  @doc "`memory.fill(dst, val, n)` for transpiled code — mirrors the interpreter (byte fill, bounds-trapped)."
  def guest_memory_fill(dst, val, n) do
    if n > 0 do
      mem = wmem()
      bounds_g!(dst, n)
      for i <- 0..(n - 1)//1, do: store(mem, dst + i, val, 1)
    end

    :ok
  end

  @doc """
  `memory.size` for TRANSPILED code — current page count read from the shared `:washy_mem_pages`
  atomics (mirrors the interpreter, which reads `rt.mem_pages`; same backing).
  """
  def guest_memory_size do
    :atomics.get(Process.get(:washy_mem_pages), 1)
  end

  @doc """
  Bounds-checked little-endian UNSIGNED integer load of `n` bytes at `addr` for TRANSPILED code.
  Reads `:washy_mem` from the process dict per access (so a grown backing is seen), traps
  `:out_of_bounds` against the logical memory size — byte-identical to the interpreter's `gload/3`.
  """
  def guest_load(addr, n) do
    bounds_g!(addr, n)
    load(wmem(), addr, n)
  end

  @doc """
  Bounds-checked SIGNED integer load (load8_s / load16_s): load `n` bytes unsigned, then sign-extend
  from `n*8` bits into the unsigned i32 representation — mirrors the interpreter's `sext(gload(..), bits)`.
  """
  def guest_load_s(addr, n) do
    bounds_g!(addr, n)
    sext(load(wmem(), addr, n), n * 8)
  end

  @doc "Bounds-checked signed load that sign-extends to 64 bits (i64 partial loads). Matches the interpreter's `{:i64_load, _, n, true}` (`sext64(v, n*8)`)."
  def guest_load_s64(addr, n) do
    bounds_g!(addr, n)
    sext64(load(wmem(), addr, n), n * 8)
  end

  @doc """
  Bounds-checked little-endian integer store of the low `n` bytes of `val` at `addr` for TRANSPILED
  code — byte-identical to the interpreter's `gstore/4`. Returns `:ok`.
  """
  def guest_store(addr, val, n) do
    bounds_g!(addr, n)
    store(wmem(), addr, val, n)
  end

  # Atomic read-modify-write host helper for the asm lane — same byte math as the interpreter's
  # {:atomic_rmw, ...} step. `opc`: 0=add 1=sub 2=and 3=or 4=xor 5=xchg. Returns the OLD value.
  @doc false
  def guest_atomic_rmw(addr, val, n, opc) do
    bounds_g!(addr, n)
    old = load(wmem(), addr, n)

    new =
      case opc do
        0 -> (old + val) &&& mask_n(n)
        1 -> (old - val) &&& mask_n(n)
        2 -> (old &&& val) &&& mask_n(n)
        3 -> (old ||| val) &&& mask_n(n)
        4 -> bxor(old, val) &&& mask_n(n)
        5 -> val &&& mask_n(n)
      end

    store(wmem(), addr, new, n)
    old
  end

  @doc false
  def guest_atomic_cmpxchg(addr, expected, repl, n) do
    bounds_g!(addr, n)
    old = load(wmem(), addr, n)
    if old == (expected &&& mask_n(n)), do: store(wmem(), addr, repl, n)
    old
  end

  # bounds check for the bulk-memory host helpers — same limit the interpreter's bounds!/3 uses, read
  # from the shared :washy_mem_pages dict (so transpiled + interpreted bulk ops trap identically).
  defp bounds_g!(addr, n) do
    limit = :atomics.get(Process.get(:washy_mem_pages), 1) * 65536
    if addr < 0 or addr + n > limit, do: trap!(:out_of_bounds)
  end

  # mutable globals as an `:atomics` array; initial values come from each global's const init expression.
  defp new_globals([]), do: nil

  defp new_globals(globals) do
    ref = :atomics.new(length(globals), signed: false)
    stub = %{mod: nil, mem: nil, globals: nil, fuel: cfuel()}

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

  # Current logical table size: the runtime counter (after grows) or the module's declared min.
  defp table_size(rt), do: Process.get(:washy_table_size) || table_min(rt)
  defp table_min(rt), do: (case rt.mod.table_type do {min, _} -> min; _ -> 0 end)
  # An ascending index range [lo, hi) that's empty when hi <= lo (//1 step avoids a descending range).
  defp grow_range(lo, hi), do: lo..(hi - 1)//1

  # ── exception-handling helpers (exnref) ──
  # A tag's value arity = the param count of its declared function type.
  defp tag_arity(rt, tagidx) do
    typeidx = Enum.at(rt.mod.tags, tagidx)
    {params, _results} = Enum.at(rt.mod.types, typeidx)
    length(params)
  end

  # The first catch clause that matches `tag` (catch_all/catch_all_ref match any), or nil.
  defp match_catch(catches, tag) do
    Enum.find(catches, fn
      {:catch, t, _l} -> t == tag
      {:catch_ref, t, _l} -> t == tag
      {:catch_all, _l} -> true
      {:catch_all_ref, _l} -> true
    end)
  end

  # Push the caught values (+ optional exnref) onto the try_table's entry stack, then branch to the
  # clause's label (relative to the try_table frame: label 0 = exit the try_table).
  defp handle_catch(clause, tag, vals, stack, l) do
    pushed =
      case clause do
        {:catch, _t, _label} -> Enum.reverse(vals) ++ stack
        {:catch_ref, _t, _label} -> [{:exnref, tag, vals} | Enum.reverse(vals) ++ stack]
        {:catch_all, _label} -> stack
        {:catch_all_ref, _label} -> [{:exnref, tag, vals} | stack]
      end

    label = elem(clause, tuple_size(clause) - 1)
    if label == 0, do: {:next, pushed, l}, else: {:br, label - 1, pushed, l}
  end

  defp new_table(elements, globals) do
    stub = %{mod: nil, mem: nil, globals: globals, table: %{}, fuel: cfuel()}

    Enum.reduce(elements, %{}, fn {offset, funcs}, acc ->
      {_sig, [base | _], _l} = run(offset, [], {}, stub)
      funcs |> Enum.with_index() |> Enum.reduce(acc, fn {f, i}, a -> Map.put(a, base + i, f) end)
    end)
  end

  # Copy each ACTIVE data segment's bytes into linear memory at its (const-expr) offset.
  defp init_data(_globals, []), do: :ok

  defp init_data(globals, data) do
    stub = %{mod: nil, mem: nil, globals: globals, fuel: cfuel()}

    Enum.each(data, fn
      {:passive, _bytes} ->
        :ok

      {:active, offset_expr, bytes} ->
        {_sig, [addr | _], _l} = run(offset_expr, [], {}, stub)
        bytes |> :binary.bin_to_list() |> Enum.with_index() |> Enum.each(fn {b, i} -> store(wmem(), addr + i, b, 1) end)
    end)
  end

  # The function index space: imports occupy [0, n_imports); local funcs follow. Dispatch a global index.
  defp call_fn(rt, fidx, args) do
    ni = length(rt.mod.imports)
    if fidx < ni,
      do: call_host(rt, Enum.at(rt.mod.imports, fidx), args),
      else: invoke(rt, fidx - ni, args)
  end

  # Invoke LOCAL function `local_idx`. Lazy tiered dispatch when enabled: a function already compiled to
  # native BEAM runs there (same shared mem/globals/fuel ⇒ identical, oracle-verified); a hot-but-cold
  # function (call count crossed the threshold) gets compiled ON DEMAND; everything else interprets.
  defp invoke(rt, local_idx, args) do
    case Map.get(rt, :lazy) do
      {counts, threshold, async?} -> lazy_invoke(rt, local_idx, args, counts, threshold, async?)
      _ -> interp_invoke(rt, local_idx, args)
    end
  end

  defp lazy_invoke(rt, local_idx, args, counts, threshold, async?) do
    gfidx = local_idx + rt.ni
    jit = Process.get(:washy_jit, %{})

    case Map.get(jit, gfidx) do
      {m, f, _ar} ->
        apply(m, f, args)

      :failed ->
        interp_invoke(rt, local_idx, args)

      :pending ->
        # ASYNC mode: a background compile is in flight. Adopt it the moment it lands (in the persistent
        # cache); until then keep interpreting — the run never stalls on the compile.
        case Nexus.Washy.Transpile.cached_one(rt.mod.id, gfidx) do
          {:ok, {m, f, _} = native} ->
            Process.put(:washy_jit, Map.put(jit, gfidx, native))
            apply(m, f, args)

          :error ->
            Process.put(:washy_jit, Map.put(jit, gfidx, :failed))
            interp_invoke(rt, local_idx, args)

          _ ->
            interp_invoke(rt, local_idx, args)
        end

      nil ->
        # Adopt a function already compiled (a prior run, or a background task this run) immediately —
        # this is how repeatedly-used modules run native from the first call. A cached :error means we
        # already decided not to compile it (unsupported op / too expensive) — don't re-attempt.
        case Nexus.Washy.Transpile.cached_one(rt.mod.id, gfidx) do
          {:ok, {m, f, _} = native} ->
            Process.put(:washy_jit, Map.put(jit, gfidx, native))
            apply(m, f, args)

          :error ->
            Process.put(:washy_jit, Map.put(jit, gfidx, :failed))
            interp_invoke(rt, local_idx, args)

          _ ->
            :counters.add(counts, local_idx + 1, 1)

            if :counters.get(counts, local_idx + 1) >= threshold do
              tier_hot(rt, local_idx, args, gfidx, jit, async?)
            else
              interp_invoke(rt, local_idx, args)
            end
        end
    end
  end

  # A function crossed the hotness threshold. ASYNC: kick off a background compile, mark :pending, keep
  # interpreting this call (no stall — the compile storm is spread across the background). SYNC: compile
  # now and dispatch native (deterministic — used by tests and where blocking is fine).
  defp tier_hot(rt, local_idx, args, gfidx, jit, true) do
    Nexus.Washy.Transpile.compile_one_async(rt.mod, gfidx)
    Process.put(:washy_jit, Map.put(jit, gfidx, :pending))
    interp_invoke(rt, local_idx, args)
  end

  defp tier_hot(rt, local_idx, args, gfidx, jit, false) do
    entry =
      case Nexus.Washy.Transpile.compile_one(rt.mod, gfidx) do
        {:ok, native} -> native
        :error -> :failed
      end

    Process.put(:washy_jit, Map.put(jit, gfidx, entry))

    case entry do
      {m, f, _ar} -> apply(m, f, args)
      :failed -> interp_invoke(rt, local_idx, args)
    end
  end

  defp interp_invoke(rt, local_idx, args) do
    if :atomics.add_get(rt.depth, 1, 1) > rt.max_depth, do: trap!(:stack_exhausted)
    {nlocals, instrs} = Enum.at(rt.mod.code, local_idx)
    locals = (args ++ List.duplicate(0, nlocals)) |> List.to_tuple()
    {_sig, stack, _l} = run(instrs, [], locals, rt)
    :atomics.sub(rt.depth, 1, 1)

    case stack do
      [top | _] -> top
      [] -> nil
    end
  end

  # HOST IMPORTS = pure Elixir functions (this is the host-mediation seam — caps/tenant/Membrane live here).
  # WASI `fd_write(fd, iovs, iovs_len, nwritten_ptr)`: gather the iovec byte ranges from memory, capture
  # writes to stdout/stderr, store the byte count, return errno 0.
  defp call_host(rt, {_m, "fd_write", _t}, [fd, iovs, iovs_len, nwritten]) do
    data = gather_iovs(wmem(), iovs, iovs_len)
    cond do
      fd in [1, 2] -> Process.put(:washy_out, [data | Process.get(:washy_out, [])])
      true -> file_write(fd, data)
    end

    store(wmem(), nwritten, byte_size(data), 4)
    0
  end

  defp call_host(_rt, {_m, "proc_exit", _t}, [code]), do: throw({:washy_exit, code})

  # host_exec(cmd_ptr, cmd_len, in_ptr, in_len) — the guest asks the host to run `cmd` with `in` as
  # stdin. The host runs that program's wasm module (host_exec/3), STASHES its output + exit code, and
  # returns the output byte length (or -1 if the program isn't found). The guest then pulls the bytes
  # with host_exec_read — a pipe-friendly ABI so a shell can feed one stage's output into the next.
  defp call_host(rt, {_m, "host_exec", _t}, [cmd_ptr, cmd_len, in_ptr, in_len]) do
    argv = read_bytes(wmem(), cmd_ptr, cmd_len) |> String.split()
    stdin = read_bytes(wmem(), in_ptr, in_len)

    case argv do
      [prog | _] ->
        # an optional per-run EXEC POLICY (set by the caller) can refuse a command before it runs — the
        # generic seam connection-scope enforcement rides on: the app maps argv → a connection grant and
        # denies a blocked one (exit 126, fails closed). The runtime knows nothing about connections.
        case exec_policy_hook(argv) do
          {:deny, reason} ->
            stash_exec("#{prog}: #{reason}\n", 126)

          :ok ->
            # a HOST CAPABILITY (work/agent/request/web) mid-pipe routes to the host dispatcher (the
            # Membrane), not to a wasm program — so a cap composes inside a pipeline, not just as word #1.
            case host_dispatch_hook(argv, stdin) do
              {out, code} ->
                stash_exec(out, code)

              :not_host ->
                if resolve_program(prog) do
                  {out, code} = host_exec(argv, stdin)
                  stash_exec(out, code)
                else
                  -1
                end
            end
        end

      [] ->
        -1
    end
  end

  # an optional per-run exec policy (set by the caller): `(argv) -> :ok | {:deny, reason}`.
  defp exec_policy_hook(argv) do
    case Process.get(:washy_exec_policy) do
      f when is_function(f, 1) -> f.(argv)
      _ -> :ok
    end
  end

  defp stash_exec(out, code) do
    Process.put(:washy_exec_out, out)
    Process.put(:washy_exec_code, code)
    byte_size(out)
  end

  # an optional host-cap dispatcher (set by the agent shell): `(argv, stdin) -> {out, code} | :not_host`
  defp host_dispatch_hook(argv, stdin) do
    case Process.get(:washy_host_dispatch) do
      f when is_function(f, 2) -> f.(argv, stdin)
      _ -> :not_host
    end
  end

  # host_exec_read(buf_ptr) — copy the stashed child output into guest memory; return the child's exit
  # code. Pairs with host_exec (the guest sizes its buffer from host_exec's return, then reads).
  defp call_host(rt, {_m, "host_exec_read", _t}, [buf_ptr]) do
    write_bytes(wmem(), buf_ptr, Process.get(:washy_exec_out, ""))
    Process.get(:washy_exec_code, 0)
  end

  # host_http — the thesis's network emulation: wasm has no sockets, so a guest's HTTP call is handed to
  # the host, which performs it (TLS + egress, SSRF-guarded) and STASHES the response. Same pipe-friendly
  # ABI as host_exec: returns the response BODY length (or -1 if no transport is wired); host_http_read
  # copies the body into the guest's buffer and returns the HTTP status. The request bytes are opaque to
  # the runtime — a caller-set `:washy_http` hook interprets them (so washy carries no HTTP policy).
  defp call_host(rt, {_m, "host_http", _t}, [req_ptr, req_len]) do
    req = read_bytes(wmem(), req_ptr, req_len)

    case http_hook(req) do
      {body, status} when is_binary(body) ->
        Process.put(:washy_http_out, body)
        Process.put(:washy_http_status, status)
        byte_size(body)

      _ ->
        -1
    end
  end

  defp call_host(rt, {_m, "host_http_read", _t}, [buf_ptr]) do
    write_bytes(wmem(), buf_ptr, Process.get(:washy_http_out, ""))
    Process.get(:washy_http_status, 0)
  end

  # ── Beam.* JS↔OTP interop host seam (wb-wzgu/north-star) ──────────────────────────────────────────
  # The bridge from a guest's `Beam` global (host imports) to `Nexus.Washy.Actor` (the persistent
  # guest-actor mechanism). ABI: handles are STRINGS (an encoded pid), messages/args/replies are JSON
  # bytes (the Term bridge), all read/written through guest memory like host_exec. These clauses are
  # inert until `qjs-run.wasm` is rebuilt to import them + inject the `Beam` global (see
  # reference/beam/JS-OTP-INTEROP-DESIGN.md) — this is the host half, testable via `invoke_host`.

  # beam_self(buf_ptr) -> len : write this guest's handle (encoded pid string) into buf, return its length.
  defp call_host(_rt, {_m, "beam_self", _t}, [buf_ptr]) do
    h = pid_handle(Nexus.Washy.Actor.beam_self())
    write_bytes(wmem(), buf_ptr, h)
    byte_size(h)
  end

  # beam_spawn(src_ptr, src_len, out_ptr) -> handle_len : spawn a JS guest actor, write its handle to out.
  defp call_host(_rt, {_m, "beam_spawn", _t}, [src_ptr, src_len, out_ptr]) do
    src = read_bytes(wmem(), src_ptr, src_len)

    case Nexus.Washy.Actor.beam_spawn({:js, src}) do
      {:ok, pid} ->
        h = pid_handle(pid)
        write_bytes(wmem(), out_ptr, h)
        byte_size(h)

      _ ->
        -1
    end
  end

  # beam_send(to_ptr, to_len, msg_ptr, msg_len) -> 0 | -1 : send a JSON message to the target handle.
  defp call_host(_rt, {_m, "beam_send", _t}, [to_ptr, to_len, msg_ptr, msg_len]) do
    to = read_bytes(wmem(), to_ptr, to_len)
    msg = Nexus.Washy.Actor.Term.from_json(read_bytes(wmem(), msg_ptr, msg_len))

    case handle_pid(to) do
      nil -> -1
      pid -> if Nexus.Washy.Actor.beam_send(pid, msg) == :ok, do: 0, else: -1
    end
  end

  # beam_call(name_ptr, name_len, args_ptr, args_len, out_ptr) -> reply_len : sync call to an Elixir
  # handler, write the JSON reply into out.
  defp call_host(_rt, {_m, "beam_call", _t}, [name_ptr, name_len, args_ptr, args_len, out_ptr]) do
    name = read_bytes(wmem(), name_ptr, name_len)
    args = Nexus.Washy.Actor.Term.from_json(read_bytes(wmem(), args_ptr, args_len))
    args = if is_list(args), do: args, else: [args]

    reply =
      case Nexus.Washy.Actor.beam_call(name, args) do
        {:ok, r} -> r
        {:error, e} -> %{"error" => inspect(e)}
        r -> r
      end

    json = Nexus.Washy.Actor.Term.to_json(reply)
    write_bytes(wmem(), out_ptr, json)
    byte_size(json)
  end

  # beam_recv(out_ptr) -> len : write the message the Actor stashed for this re-entry (JSON) into out.
  defp call_host(_rt, {_m, "beam_recv", _t}, [out_ptr]) do
    json = Process.get(:washy_beam_inbox, "null")
    write_bytes(wmem(), out_ptr, json)
    byte_size(json)
  end

  # beam_link(to_ptr, to_len) -> 0 | -1 : monitor a peer (handle/name) from the calling actor.
  defp call_host(_rt, {_m, "beam_link", _t}, [to_ptr, to_len]) do
    to = read_bytes(wmem(), to_ptr, to_len)
    target = handle_pid(to) || to
    if Nexus.Washy.Actor.beam_link(target) == :ok, do: 0, else: -1
  end

  # beam_process_info(to_ptr, to_len, out_ptr) -> len : JSON of {reductions,memory,message_queue_len}.
  # An empty target (len 0) means "this actor".
  defp call_host(_rt, {_m, "beam_process_info", _t}, [to_ptr, to_len, out_ptr]) do
    target = if to_len > 0, do: (read_bytes(wmem(), to_ptr, to_len) |> then(&(handle_pid(&1) || &1))), else: nil
    json = Nexus.Washy.Actor.process_info(target) |> Nexus.Washy.Actor.Term.to_json()
    write_bytes(wmem(), out_ptr, json)
    byte_size(json)
  end

  # beam_system_info(out_ptr) -> len : JSON of VM-wide counters (process_count, atom_count, run_queue, …).
  defp call_host(_rt, {_m, "beam_system_info", _t}, [out_ptr]) do
    json = Nexus.Washy.Actor.system_info() |> Nexus.Washy.Actor.Term.to_json()
    write_bytes(wmem(), out_ptr, json)
    byte_size(json)
  end

  # timer_set(id, ms) -> 0 : arm a BEAM timer on the owning actor; on fire it re-enters wb_timer(id).
  defp call_host(_rt, {_m, "timer_set", _t}, [id, ms]) do
    Nexus.Washy.Actor.timer_set(id, ms)
    0
  end

  # timer_clear(id) -> 0 : cancel a pending timer on the owning actor.
  defp call_host(_rt, {_m, "timer_clear", _t}, [id]) do
    Nexus.Washy.Actor.timer_clear(id)
    0
  end

  # io_recv(out_ptr) -> len : write the {id,ok,value} completion envelope the actor stashed for this
  # wb_complete re-entry (JSON) into guest memory. Mirrors beam_recv; the generic async-completion read.
  defp call_host(_rt, {_m, "io_recv", _t}, [out_ptr]) do
    json = Process.get(:washy_io_inbox, "null")
    write_bytes(wmem(), out_ptr, json)
    byte_size(json)
  end

  # handles ARE encoded pids (stable, registry-free). Guard list_to_pid against a bogus guest string.
  defp pid_handle(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> to_string()
  defp pid_handle(other), do: to_string(other)

  defp handle_pid(h) do
    :erlang.list_to_pid(to_charlist(h))
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # an optional host HTTP transport (set by the caller): `(request_bytes) -> {body, status} | :none`.
  defp http_hook(req) do
    case Process.get(:washy_http) do
      f when is_function(f, 1) -> f.(req)
      _ -> :none
    end
  end

  # ── host-brokered TCP (Layer 2) — wasm32-wasip1 has no sockets, so a guest's connect/send/recv is
  # performed by the host (real sockets, SSRF-guarded) and the bytes shuttle across the membrane. This
  # is the general path for raw std::net / socket-aware tokio that Layer 1's HTTP shim doesn't cover.
  # Generic: a caller-set `:washy_sock` hook owns the transport; washy only maps a guest fd → its ref.
  defp call_host(rt, {_m, "host_tcp_connect", _t}, [host_ptr, host_len, port]) do
    host = read_bytes(wmem(), host_ptr, host_len)

    case sock_hook({:connect, host, port}) do
      {:ok, ref} ->
        fd = Process.get(:washy_nextfd, 4)
        Process.put(:washy_nextfd, fd + 1)
        Process.put(:washy_sockets, Map.put(Process.get(:washy_sockets, %{}), fd, ref))
        fd

      _ ->
        -1
    end
  end

  defp call_host(rt, {_m, "host_tcp_send", _t}, [fd, buf_ptr, len]) do
    case Map.get(Process.get(:washy_sockets, %{}), fd) do
      nil ->
        -1

      ref ->
        case sock_hook({:send, ref, read_bytes(wmem(), buf_ptr, len)}) do
          n when is_integer(n) -> n
          _ -> -1
        end
    end
  end

  defp call_host(rt, {_m, "host_tcp_recv", _t}, [fd, buf_ptr, cap]) do
    case Map.get(Process.get(:washy_sockets, %{}), fd) do
      nil ->
        -1

      ref ->
        case sock_hook({:recv, ref, cap}) do
          {:data, bin} ->
            bin = binary_part(bin, 0, min(byte_size(bin), cap))
            write_bytes(wmem(), buf_ptr, bin)
            byte_size(bin)

          :eof ->
            0

          _ ->
            -1
        end
    end
  end

  defp call_host(rt, {_m, "host_tcp_close", _t}, [fd]) do
    socks = Process.get(:washy_sockets, %{})

    case Map.get(socks, fd) do
      nil ->
        -1

      ref ->
        sock_hook({:close, ref})
        Process.put(:washy_sockets, Map.delete(socks, fd))
        0
    end
  end

  # an optional host TCP transport (set by the caller): `(op) -> result` where op is
  # `{:connect, host, port}` → `{:ok, ref} | {:error, _}`, `{:send, ref, data}` → bytes_sent,
  # `{:recv, ref, max}` → `{:data, bin} | :eof | {:error, _}`, `{:close, ref}` → :ok.
  defp sock_hook(op) do
    case Process.get(:washy_sock) do
      f when is_function(f, 1) -> f.(op)
      _ -> {:error, :no_transport}
    end
  end

  # WASI args (argv): argc < 2 so the shell reads its command line from stdin.
  defp call_host(rt, {_m, "args_sizes_get", _t}, [argc_ptr, bufsize_ptr]) do
    argv = Process.get(:washy_argv, ["sh"])
    store(wmem(), argc_ptr, length(argv), 4)
    store(wmem(), bufsize_ptr, Enum.reduce(argv, 0, fn a, acc -> acc + byte_size(a) + 1 end), 4)
    0
  end

  defp call_host(rt, {_m, "args_get", _t}, [argv_ptr, buf_ptr]) do
    Process.get(:washy_argv, ["sh"])
    |> Enum.reduce({argv_ptr, buf_ptr}, fn a, {pp, bp} ->
      store(wmem(), pp, bp, 4)
      write_bytes(wmem(), bp, a)
      store(wmem(), bp + byte_size(a), 0, 1)
      {pp + 4, bp + byte_size(a) + 1}
    end)

    0
  end

  # WASI read: fd 0 = stdin (command line); a file fd = the virtual filesystem; else EOF.
  defp call_host(rt, {_m, "fd_read", _t}, [fd, iovs, iovs_len, nread_ptr]) do
    cap = iov_capacity(wmem(), iovs, iovs_len)
    data = if fd == 0, do: stdin_take(cap), else: file_read(fd, cap)
    store(wmem(), nread_ptr, scatter_iovs(wmem(), iovs, iovs_len, data), 4)
    0
  end

  # fd metadata: a file fd is a regular file (4); stdin/out/err are character devices (2).
  defp call_host(rt, {_m, "fd_fdstat_get", _t}, [fd, ptr]) do
    # fs_filetype: 3 = directory, 4 = regular file, 2 = character device (stdio). Grant full rights so a
    # tool checks out readdir/read/write on whatever it opened.
    ft =
      case Map.get(Process.get(:washy_fds, %{}), fd) do
        {:dir, _} -> 3
        nil -> 2
        _ -> 4
      end

    store(wmem(), ptr, ft, 1)
    store(wmem(), ptr + 8, @mask64, 8)
    store(wmem(), ptr + 16, @mask64, 8)
    0
  end

  # ONE preopened dir at fd 3 = the virtual /work, so the shell resolves /work/<path> against it.
  defp call_host(rt, {_m, "fd_prestat_get", _t}, [3, ptr]) do
    store(wmem(), ptr, 0, 1)
    store(wmem(), ptr + 4, byte_size(preopen_name()), 4)
    0
  end

  defp call_host(_rt, {_m, "fd_prestat_get", _t}, [_fd, _ptr]), do: 8

  defp call_host(rt, {_m, "fd_prestat_dir_name", _t}, [3, ptr, len]) do
    name = preopen_name()
    write_bytes(wmem(), ptr, binary_part(name, 0, min(len, byte_size(name))))
    0
  end

  defp call_host(_rt, {_m, "fd_prestat_dir_name", _t}, _args), do: 8

  # open a path (relative to the /work preopen) in the virtual FS — create/truncate per oflags.
  defp call_host(rt, {_m, "path_open", _t}, [_dirfd, _df, path_ptr, path_len, oflags, _rb, _ri, ff, ofd_ptr]) do
    rel = read_bytes(wmem(), path_ptr, path_len)
    exists = Nexus.Washy.VFS.has?(rel)
    creat = (oflags &&& 1) != 0
    trunc = (oflags &&& 8) != 0
    append = (ff &&& 0x0001) != 0

    cond do
      # opening a DIRECTORY (the /work root or an implied subdir) — succeed with a dir fd (no content)
      dir_path?(rel) ->
        fd = Process.get(:washy_nextfd, 4)
        Process.put(:washy_nextfd, fd + 1)
        Process.put(:washy_fds, Map.put(Process.get(:washy_fds, %{}), fd, {:dir, rel}))
        store(wmem(), ofd_ptr, fd, 4)
        0

      not exists and not creat ->
        44

      true ->
      if not exists or trunc, do: Nexus.Washy.VFS.put(rel, "")
      # APPEND fdflag positions the fd at end-of-file so writes extend rather than overwrite
      off = if append, do: byte_size(Nexus.Washy.VFS.get(rel) || ""), else: 0
      fd = Process.get(:washy_nextfd, 4)
      Process.put(:washy_nextfd, fd + 1)
      Process.put(:washy_fds, Map.put(Process.get(:washy_fds, %{}), fd, {rel, off}))
      store(wmem(), ofd_ptr, fd, 4)
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
        store(wmem(), ofs_ptr, noff, 8)
        0

      _ ->
        70
    end
  end

  # WASI environment — served from the run-scoped `:washy_env` (a list of "KEY=VALUE" strings, set by
  # the caller; empty by default). Same NUL-terminated, pointer-table encoding as args_get. This is the
  # generic seam credential-injection rides on: the app builds the env (e.g. a CLI connection's token)
  # and sets `:washy_env`; the runtime knows nothing about what the vars mean.
  defp call_host(rt, {_m, "environ_sizes_get", _t}, [c_ptr, b_ptr]) do
    env = Process.get(:washy_env, [])
    store(wmem(), c_ptr, length(env), 4)
    store(wmem(), b_ptr, Enum.reduce(env, 0, fn e, acc -> acc + byte_size(e) + 1 end), 4)
    0
  end

  defp call_host(rt, {_m, "environ_get", _t}, [environ_ptr, buf_ptr]) do
    Process.get(:washy_env, [])
    |> Enum.reduce({environ_ptr, buf_ptr}, fn e, {pp, bp} ->
      store(wmem(), pp, bp, 4)
      write_bytes(wmem(), bp, e)
      store(wmem(), bp + byte_size(e), 0, 1)
      {pp + 4, bp + byte_size(e) + 1}
    end)

    0
  end
  # REAL time: clock id 0 = realtime (wall, since epoch), 1 = monotonic — both in nanoseconds. A fixed
  # `:washy_clock` override (tests/determinism) still wins when set. Previously returned 0 always, which
  # silently broke every Date.now()/timestamp/timeout in a guest.
  defp call_host(rt, {_m, "clock_time_get", _t}, [id, _prec, time_ptr]) do
    t = Process.get(:washy_clock) || clock_now(id)
    store(wmem(), time_ptr, t, 8)
    0
  end

  # REAL randomness from the host CSPRNG. Previously wrote ZEROS, which silently made crypto/UUIDs/
  # hashing/Math.random deterministic-and-wrong. A `:washy_random` override (tests) still wins.
  defp call_host(rt, {_m, "random_get", _t}, [buf, len]) do
    bytes = Process.get(:washy_random) || :crypto.strong_rand_bytes(len)
    write_bytes(wmem(), buf, binary_part(bytes, 0, min(len, byte_size(bytes))) |> pad_to(len))
    0
  end
  defp call_host(_rt, {_m, "sched_yield", _t}, _args), do: 0
  defp call_host(_rt, {_m, "fd_sync", _t}, _args), do: 0
  defp call_host(_rt, {_m, "fd_datasync", _t}, _args), do: 0

  # file stat: report a regular file with the VFS content's size; dir/path ops succeed minimally.
  defp call_host(rt, {_m, "fd_filestat_get", _t}, [fd, ptr]) do
    {ftype, size} =
      case Map.get(Process.get(:washy_fds, %{}), fd) do
        {:dir, _} -> {3, 0}
        {path, _} -> {4, byte_size(Nexus.Washy.VFS.get(path) || "")}
        _ -> {4, 0}
      end

    # filestat: dev(8) ino(8) filetype(1) +pad(7) nlink(8) size(8) atim(8) mtim(8) ctim(8)
    store(wmem(), ptr + 16, ftype, 1)
    store(wmem(), ptr + 32, size, 8)
    0
  end

  defp call_host(rt, {_m, "path_filestat_get", _t}, [_dirfd, _flags, path_ptr, path_len, ptr | _]) do
    rel = read_bytes(wmem(), path_ptr, path_len)

    cond do
      dir_path?(rel) -> (store(wmem(), ptr + 16, 3, 1); store(wmem(), ptr + 32, 0, 8); 0)
      (c = Nexus.Washy.VFS.get(rel)) != nil -> (store(wmem(), ptr + 16, 4, 1); store(wmem(), ptr + 32, byte_size(c), 8); 0)
      true -> 44
    end
  end

  # a path that names a DIRECTORY: the /work root (".", "", "/") or an implied subdir (a prefix of a key)
  defp dir_path?(rel) do
    rel in ["", ".", "/", "/work", "/work/", "./"] or
      Enum.any?(Nexus.Washy.VFS.list(), &String.starts_with?(&1, rel <> "/"))
  end

  defp call_host(rt, {_m, "fd_tell", _t}, [fd, ptr]) do
    off = case Map.get(Process.get(:washy_fds, %{}), fd) do
      {_path, o} -> o
      _ -> 0
    end
    store(wmem(), ptr, off, 8)
    0
  end

  defp call_host(_rt, {_m, "fd_filestat_set_size", _t}, _args), do: 0
  defp call_host(_rt, {_m, "fd_filestat_set_times", _t}, _args), do: 0
  # list the /work directory: WASI dirents (24-byte header {d_next, d_ino, d_namlen, d_type} + name)
  # streamed from `cookie`, truncated to `buf_len`. `d_next = index+1` lets the guest resume. Previously
  # returned 8 (ENOSYS), so ls / os.listdir / fs.readdir all failed.
  defp call_host(rt, {_m, "fd_readdir", _t}, [_fd, buf, buf_len, cookie, bufused_ptr]) do
    stream =
      readdir_entries()
      |> Enum.with_index()
      |> Enum.drop(cookie)
      |> Enum.map(fn {{name, type}, idx} ->
        <<idx + 1::64-little, 0::64-little, byte_size(name)::32-little, type, 0::size(24)>> <> name
      end)
      |> IO.iodata_to_binary()

    out = binary_part(stream, 0, min(buf_len, byte_size(stream)))
    write_bytes(wmem(), buf, out)
    store(wmem(), bufused_ptr, byte_size(out), 4)
    0
  end

  # the /work entries: top-level files (type 4) + implied dirs from nested keys (type 3), plus . and ..
  defp readdir_entries do
    files =
      Nexus.Washy.VFS.list()
      |> Enum.map(fn key ->
        case String.split(key, "/", parts: 2) do
          [name] -> {name, 4}
          [dir, _] -> {dir, 3}
        end
      end)
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.sort()

    [{".", 3}, {"..", 3} | files]
  end
  defp call_host(_rt, {_m, "poll_oneoff", _t}, _args), do: 0
  defp call_host(_rt, {_m, "path_create_directory", _t}, _args), do: 0
  # real file management over the VFS — was no-op stubs, so rm/mv silently did nothing
  defp call_host(_rt, {_m, "path_remove_directory", _t}, _args), do: 0

  defp call_host(rt, {_m, "path_unlink_file", _t}, [_dirfd, path_ptr, path_len]) do
    rel = read_bytes(wmem(), path_ptr, path_len)
    if Nexus.Washy.VFS.has?(rel), do: (Nexus.Washy.VFS.delete(rel); 0), else: 44
  end

  defp call_host(rt, {_m, "path_rename", _t}, [_ofd, op, ol, _nfd, np, nl]) do
    from = read_bytes(wmem(), op, ol)
    to = read_bytes(wmem(), np, nl)

    case Nexus.Washy.VFS.get(from) do
      nil -> 44
      content -> (Nexus.Washy.VFS.put(to, content); Nexus.Washy.VFS.delete(from); 0)
    end
  end
  defp call_host(_rt, {_m, "path_link", _t}, _args), do: 0
  defp call_host(_rt, {_m, "path_symlink", _t}, _args), do: 0
  defp call_host(_rt, {_m, "path_readlink", _t}, _args), do: 44

  # Generic host bridge (Wave 0 fan-out seam): __host(name,args) — sync. Decode JSON name+args, route to the
  # concern module by convention (HostFs/HostNet/…), JSON-encode the result back. Concerns add NO clause here.
  defp call_host(_rt, {_m, "host_call", _t}, [np, nl, ap, al, op, _oc]) do
    name = read_bytes(wmem(), np, nl)
    args = Nexus.Washy.Actor.Term.from_json(read_bytes(wmem(), ap, al))
    json = Nexus.Washy.HostIO.dispatch_call(name, List.wrap(args)) |> Nexus.Washy.Actor.Term.to_json()
    write_bytes(wmem(), op, json)
    byte_size(json)
  end

  # __host_async(name,args) — fire-and-forget; the concern resolves the guest promise `id` later via
  # Actor.io_complete → the wb_complete re-entry. Returns 0.
  defp call_host(_rt, {_m, "host_call_async", _t}, [np, nl, ap, al, id]) do
    name = read_bytes(wmem(), np, nl)
    args = Nexus.Washy.Actor.Term.from_json(read_bytes(wmem(), ap, al))
    Nexus.Washy.HostIO.dispatch_async(name, List.wrap(args), id)
  end

  defp call_host(_rt, {_m, name, _t}, _args), do: raise("washy: unimplemented host import '#{name}'")

  @doc "Write `bin` byte-for-byte into the packed memory `mem` at `addr` (little-endian, same layout the guest sees)."
  def write_bytes(mem, addr, bin) do
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

  @doc "Read `len` bytes from packed memory `mem` at `addr` (little-endian, same layout the guest sees)."
  def read_bytes(_mem, _addr, 0), do: ""
  def read_bytes(mem, addr, len), do: for(j <- 0..(len - 1)//1, do: load(mem, addr + j, 1)) |> :erlang.list_to_binary()

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

  # real wall-clock time in nanoseconds (always positive); used by clock_time_get for any clock id
  defp clock_now(_id), do: System.os_time(:nanosecond)

  # v128 load/store: 16 bytes <-> a 16-byte binary
  defp vload(mem, addr), do: for(i <- 0..15, do: mget(mem, addr + i)) |> :erlang.list_to_binary()
  defp vstore(mem, addr, <<bytes::binary-size(16)>>), do: bytes |> :binary.bin_to_list() |> Enum.with_index() |> Enum.each(fn {b, i} -> mput(mem, addr + i, b) end)

  # Type-driven arity for a global function index (import or local).
  @doc """
  Packed `:atomics` slot count a fresh instance allocates for linear memory — `max(1, min) * 8192`
  (8 bytes/slot). Pure function of the module's declared `min` pages; the per-cell memory footprint
  is `mem_slots(mod) * 8` bytes. Used by density introspection / the ops gauge. `0` if no memory.
  """
  def mem_slots(%__MODULE__{mem: nil}), do: 0
  def mem_slots(%__MODULE__{mem: {min, _max}}), do: max(1, min) * @page_words

  @doc """
  Resolve an exported LOCAL function to `{arity, nlocals, instrs}` — the same structured body the
  interpreter runs, for the transpiler / static analysis to consume. Raises if `name` is an import.
  """
  def function_body(%__MODULE__{} = mod, name) do
    fidx = Map.fetch!(mod.exports, name)
    ni = length(mod.imports)
    if fidx < ni, do: raise(ArgumentError, "#{name} is an imported function, not transpilable")
    local_idx = fidx - ni
    {nlocals, instrs} = Enum.at(mod.code, local_idx)
    {params, _results} = Enum.at(mod.types, Enum.at(mod.funcs, local_idx))
    {length(params), nlocals, instrs}
  end

  # the resolved `{params, results}` signature of a function (import or local) by global index
  defp func_type(mod, fidx) do
    ni = length(mod.imports)
    tidx = if fidx < ni, do: elem(Enum.at(mod.imports, fidx), 2), else: Enum.at(mod.funcs, fidx - ni)
    Enum.at(mod.types, tidx)
  end

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
    # charge one unit of fuel per instruction; a guest that exhausts its budget traps (bounds runaway
    # work). `sub_get` is atomic + allocation-free — the safety tax on the hot path is one atomics op.
    if :atomics.sub_get(rt.fuel, 1, 1) < 0, do: trap!(:out_of_fuel)

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

  # ── Exception handling (exnref proposal, WASIX §0). An exception unwinds the BEAM stack via an Elixir
  # throw `{:wasm_exc, tag, vals}` until a try_table catches a matching tag. exnref = {:exnref, tag, vals}.
  # The catch's label is a br target in the try_table frame (label 0 = exit the try_table), same as block. ──
  defp step({:throw, tagidx}, stack, l, rt) do
    arity = tag_arity(rt, tagidx)
    {vals, _rest} = Enum.split(stack, arity)
    throw({:wasm_exc, tagidx, Enum.reverse(vals)})
  end

  defp step({:throw_ref}, [exnref | _s], l, _rt) do
    case exnref do
      {:exnref, tag, vals} -> throw({:wasm_exc, tag, vals})
      :null -> trap!(:null_exnref)
      _ -> trap!(:not_an_exnref)
    end
    {:next, [], l}
  end

  defp step({:try_table, catches, body}, stack, l, rt) do
    result =
      try do
        run(body, stack, l, rt)
      catch
        :throw, {:wasm_exc, tag, vals} = exc ->
          case match_catch(catches, tag) do
            nil -> throw(exc)
            clause -> {:caught, clause, tag, vals}
          end
      end

    case result do
      {:next, s, l} -> {:next, s, l}
      {:br, 0, s, l} -> {:next, s, l}
      {:br, n, s, l} -> {:br, n - 1, s, l}
      {:return, s, l} -> {:return, s, l}
      {:caught, clause, tag, vals} -> handle_catch(clause, tag, vals, stack, l)
    end
  end

  defp step({:br, n}, stack, l, _rt), do: {:br, n, stack, l}
  defp step({:br_if, n}, [c | stack], l, _rt), do: if(c != 0, do: {:br, n, stack, l}, else: {:next, stack, l})

  defp step({:br_table, labels, default}, [i | stack], l, _rt) do
    target = if i < length(labels), do: Enum.at(labels, i), else: default
    {:br, target, stack, l}
  end
  defp step({:return}, stack, l, _rt), do: {:return, stack, l}
  defp step({:unreachable}, _stack, _l, _rt), do: trap!(:unreachable)
  defp step({:nop}, stack, l, _rt), do: {:next, stack, l}
  defp step({:drop}, [_ | stack], l, _rt), do: {:next, stack, l}

  defp step({:i64_const, v}, stack, l, _rt), do: {:next, [v | stack], l}

  defp step({:i64_load, o, n, signed}, [a | s], l, rt) do
    v = gload(rt, a + o, n)
    v = if signed, do: sext64(v, n * 8), else: v
    {:next, [v | s], l}
  end

  defp step({:i64_store, o, n}, [v, a | s], l, rt), do: (gstore(rt, a + o, v, n); {:next, s, l})

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

  # ── Reference types + table get/set (WASIX §0). funcref = func index; null = `:null`. The table is
  # mutable, held in `:washy_table` (seeded at run start), so table.set is visible to call_indirect. ──
  defp step({:ref_null}, stack, l, _rt), do: {:next, [:null | stack], l}
  defp step({:ref_is_null}, [r | s], l, _rt), do: {:next, [if(r == :null, do: 1, else: 0) | s], l}
  defp step({:ref_func, i}, stack, l, _rt), do: {:next, [i | stack], l}

  defp step({:table_get}, [i | s], l, rt) do
    {:next, [Map.get(Process.get(:washy_table, rt.table), i, :null) | s], l}
  end

  defp step({:table_set}, [v, i | s], l, rt) do
    Process.put(:washy_table, Map.put(Process.get(:washy_table, rt.table), i, v))
    {:next, s, l}
  end

  defp step({:table_size}, stack, l, rt), do: {:next, [table_size(rt) | stack], l}

  # table.grow(init, n) → old size, or -1 (u32) if it would exceed the declared max. New slots = init.
  defp step({:table_grow}, [n, init | s], l, rt) do
    old = table_size(rt)
    new = old + n
    max = case rt.mod.table_type do {_, m} -> m; _ -> nil end

    if max != nil and new > max do
      {:next, [(-1 &&& @mask32) | s], l}
    else
      table = Enum.reduce(grow_range(old, new), Process.get(:washy_table, rt.table), fn idx, t -> Map.put(t, idx, init) end)
      Process.put(:washy_table, table)
    Process.delete(:washy_table_size)
      Process.put(:washy_table_size, new)
      {:next, [old | s], l}
    end
  end

  defp step({:table_fill}, [n, val, i | s], l, rt) do
    table = Enum.reduce(grow_range(i, i + n), Process.get(:washy_table, rt.table), fn idx, t -> Map.put(t, idx, val) end)
    Process.put(:washy_table, table)
    Process.delete(:washy_table_size)
    {:next, s, l}
  end

  defp step({:table_copy}, [n, src, dst | s], l, rt) do
    table = Process.get(:washy_table, rt.table)
    vals = Enum.map(grow_range(0, n), fn k -> Map.get(table, src + k, :null) end)
    table = vals |> Enum.with_index() |> Enum.reduce(table, fn {v, k}, t -> Map.put(t, dst + k, v) end)
    Process.put(:washy_table, table)
    Process.delete(:washy_table_size)
    {:next, s, l}
  end

  # passive element-segment ops — active elements already loaded the table at start, so these are no-ops
  # in the common case (stack-balanced). table.init pops dst/src/n; elem.drop pops nothing.
  defp step({:table_init}, [_n, _src, _dst | s], l, _rt), do: {:next, s, l}
  defp step({:elem_drop}, stack, l, _rt), do: {:next, stack, l}

  defp step({:call_indirect, typeidx}, [i | stack], l, rt) do
    # spec traps: no/null table entry → :undefined_element; entry's type ≠ the expected type → mismatch.
    f = Map.get(Process.get(:washy_table, rt.table), i)
    if f == :null, do: trap!(:undefined_element)
    if f == nil, do: trap!(:undefined_element)
    expected = Enum.at(rt.mod.types, typeidx)
    if func_type(rt.mod, f) != expected, do: trap!(:indirect_call_type_mismatch)
    {args, stack} = Enum.split(stack, length(elem(expected, 0)))
    result = call_fn(rt, f, Enum.reverse(args))
    {:next, if(result == nil, do: stack, else: [result | stack]), l}
  end

  defp step({:i32_load, o}, [a | s], l, rt), do: {:next, [gload(rt, a + o, 4) | s], l}
  defp step({:i32_load8u, o}, [a | s], l, rt), do: {:next, [gload(rt, a + o, 1) | s], l}
  defp step({:i32_load8s, o}, [a | s], l, rt), do: {:next, [sext(gload(rt, a + o, 1), 8) | s], l}
  defp step({:i32_load16u, o}, [a | s], l, rt), do: {:next, [gload(rt, a + o, 2) | s], l}
  defp step({:i32_load16s, o}, [a | s], l, rt), do: {:next, [sext(gload(rt, a + o, 2), 16) | s], l}
  defp step({:i32_store, o}, [v, a | s], l, rt), do: (gstore(rt, a + o, v, 4); {:next, s, l})
  defp step({:i32_store8, o}, [v, a | s], l, rt), do: (gstore(rt, a + o, v, 1); {:next, s, l})
  defp step({:i32_store16, o}, [v, a | s], l, rt), do: (gstore(rt, a + o, v, 2); {:next, s, l})

  # ── ATOMICS (WASIX §0). The memory is `:atomics`-backed so single-thread access is naturally atomic;
  # read-modify-write under contention (multiple BEAM "threads" on one shared memory) is the threads
  # milestone (§2). Atomic loads are always zero-extended (unsigned); fence is a no-op on this model. ──
  defp step({:atomic_fence}, stack, l, _rt), do: {:next, stack, l}
  defp step({:atomic_load, o, n}, [a | s], l, rt), do: {:next, [gload(rt, a + o, n) | s], l}
  defp step({:atomic_store, o, n}, [v, a | s], l, rt), do: (gstore(rt, a + o, v, n); {:next, s, l})

  defp step({:atomic_rmw, :cmpxchg, o, n}, [repl, expected, a | s], l, rt) do
    addr = a + o
    old = gload(rt, addr, n)
    if old == (expected &&& mask_n(n)), do: gstore(rt, addr, repl, n)
    {:next, [old | s], l}
  end

  defp step({:atomic_rmw, opname, o, n}, [v, a | s], l, rt) do
    addr = a + o
    old = gload(rt, addr, n)
    gstore(rt, addr, atomic_apply(opname, old, v, n), n)
    {:next, [old | s], l}
  end

  # memory.atomic.notify(addr, count) → woken count. No threads yet (§2) ⇒ no waiters ⇒ 0.
  defp step({:atomic_notify, _o}, [_count, _a | s], l, _rt), do: {:next, [0 | s], l}

  # memory.atomic.wait(addr, expected, timeout) → 0 ok / 1 not-equal / 2 timed-out. Without threads to
  # notify us (§2), the equal case can't truly block ⇒ report timed-out rather than deadlock.
  defp step({:atomic_wait, n, o}, [_timeout, expected, a | s], l, rt) do
    cur = gload(rt, a + o, n)
    {:next, [if(cur != (expected &&& mask_n(n)), do: 1, else: 2) | s], l}
  end
  defp step({:memory_size}, stack, l, rt), do: {:next, [:atomics.get(rt.mem_pages, 1) | stack], l}

  defp step({:memory_grow}, [n | s], l, rt) do
    old = :atomics.get(rt.mem_pages, 1)
    new = old + n
    # grow by REALLOCATING a larger packed backing + copying live words, then swap it into the dict.
    # Bounded by the per-run max_pages ceiling so a guest can never OOM the host.
    result =
      if n >= 0 and new <= rt.max_pages do
        oldmem = wmem()
        newmem = :atomics.new(new * @page_words, signed: false)
        for i <- 1..(old * @page_words)//1, do: :atomics.put(newmem, i, :atomics.get(oldmem, i))
        Process.put(:washy_mem, newmem)
        :atomics.put(rt.mem_pages, 1, new)
        old
      else
        -1 &&& @mask32
      end

    {:next, [result | s], l}
  end

  # bulk memory: copy n bytes src->dst (overlap-safe); fill n bytes at dst with a byte value
  defp step({:memory_copy}, [n, src, dst | s], l, rt), do: (if n > 0, do: (bounds!(rt, dst, n); bounds!(rt, src, n); mem_copy(wmem(), dst, src, n)); {:next, s, l})
  defp step({:memory_fill}, [n, val, dst | s], l, rt), do: (if n > 0, do: bounds!(rt, dst, n); for(i <- 0..(n - 1)//1, do: store(wmem(), dst + i, val, 1)); {:next, s, l})
  defp step({:data_drop}, stack, l, _rt), do: {:next, stack, l}

  # memory.init(dst, src, n): copy n bytes from data segment `dataidx` (at src) into memory (at dst).
  # OOB on either side traps; n=0 is a no-op. Closes the last §0 bulk-memory gap.
  defp step({:memory_init, dataidx}, [n, src, dst | s], l, rt) do
    bytes =
      case Enum.at(rt.mod.data, dataidx) do
        {:passive, b} -> b
        {:active, _o, b} -> b
        _ -> <<>>
      end

    if n > 0 do
      if src + n > byte_size(bytes), do: trap!(:out_of_bounds_data)
      bounds!(rt, dst, n)
      for i <- 0..(n - 1)//1, do: store(wmem(), dst + i, :binary.at(bytes, src + i), 1)
    end

    {:next, s, l}
  end
  defp step({:trunc_sat, n}, [a | s], l, _rt) when n in 0..3, do: {:next, [trunc_sat(a) &&& @mask32 | s], l}
  defp step({:trunc_sat, _n}, [a | s], l, _rt), do: {:next, [trunc_sat(a) &&& @mask64 | s], l}

  # floats live on the stack as BEAM floats (heterogeneous w/ ints — validation keeps types correct).
  defp step({:fconst, v}, stack, l, _rt), do: {:next, [v | stack], l}
  defp step({:f32_load, o}, [a | s], l, rt), do: {:next, [gfload(rt, a + o, 4) | s], l}
  defp step({:f64_load, o}, [a | s], l, rt), do: {:next, [gfload(rt, a + o, 8) | s], l}
  defp step({:f32_store, o}, [v, a | s], l, rt), do: (gfstore(rt, a + o, v, 4); {:next, s, l})
  defp step({:f64_store, o}, [v, a | s], l, rt), do: (gfstore(rt, a + o, v, 8); {:next, s, l})

  # v128 values live on the stack as 16-byte binaries.
  defp step({:simd, 0, off}, [a | s], l, rt), do: {:next, [gvload(rt, a + off) | s], l}      # v128.load
  defp step({:simd, 11, off}, [v, a | s], l, rt), do: (gvstore(rt, a + off, v); {:next, s, l})  # v128.store
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
  defp binop(0x6D, [b, a | s]), do: [idiv(s32(a), s32(b), -0x80000000) &&& @mask32 | s]  # i32.div_s
  defp binop(0x6E, [b, a | s]), do: [udiv(a, b) &&& @mask32 | s]                     # i32.div_u
  defp binop(0x6F, [b, a | s]), do: [irem(s32(a), s32(b)) &&& @mask32 | s]           # i32.rem_s
  defp binop(0x70, [b, a | s]), do: [urem(a, b) &&& @mask32 | s]                     # i32.rem_u
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
  defp binop(0x8B, [a | s]), do: [fabs(a, 32) | s]                                  # f32.abs
  defp binop(0x8C, [a | s]), do: [fneg(a, 32) | s]                                  # f32.neg
  defp binop(0x91, [a | s]), do: [fsqrt(a, 32) | s]                                 # f32.sqrt
  defp binop(0x92, [b, a | s]), do: [farith(a, b, :add, 32) | s]                    # f32.add
  defp binop(0x93, [b, a | s]), do: [farith(a, b, :sub, 32) | s]                    # f32.sub
  defp binop(0x94, [b, a | s]), do: [farith(a, b, :mul, 32) | s]                    # f32.mul
  defp binop(0x95, [b, a | s]), do: [farith(a, b, :div, 32) | s]                    # f32.div
  defp binop(0x96, [b, a | s]), do: [fminmax(a, b, :min, 32) | s]                   # f32.min
  defp binop(0x97, [b, a | s]), do: [fminmax(a, b, :max, 32) | s]                   # f32.max
  defp binop(0x8B, [a | s]), do: [f32r(abs(a)) | s]                                 # f32.abs
  defp binop(0x8C, [a | s]), do: [f32r(-a) | s]                                     # f32.neg
  defp binop(0x8D, [a | s]), do: [fround_unary(a, 32, &Float.ceil/1) | s]           # f32.ceil
  defp binop(0x8E, [a | s]), do: [fround_unary(a, 32, &Float.floor/1) | s]          # f32.floor
  defp binop(0x8F, [a | s]), do: [fround_unary(a, 32, fn x -> trunc(x) * 1.0 end) | s]  # f32.trunc
  defp binop(0x90, [a | s]), do: [fround_unary(a, 32, &fnearest/1) | s]             # f32.nearest
  defp binop(0x91, [a | s]), do: [f32r(:math.sqrt(a)) | s]                          # f32.sqrt
  defp binop(0x98, [b, a | s]), do: [fcopysign_nf(a, b, 32) | s]                    # f32.copysign
  defp binop(0x5B, [b, a | s]), do: [bool(fcmp(a, b, :eq)) | s]                      # f32.eq
  defp binop(0x5C, [b, a | s]), do: [bool(fcmp(a, b, :ne)) | s]                      # f32.ne
  defp binop(0x5D, [b, a | s]), do: [bool(fcmp(a, b, :lt)) | s]                      # f32.lt
  defp binop(0x5E, [b, a | s]), do: [bool(fcmp(a, b, :gt)) | s]                      # f32.gt
  defp binop(0x5F, [b, a | s]), do: [bool(fcmp(a, b, :le)) | s]                      # f32.le
  defp binop(0x60, [b, a | s]), do: [bool(fcmp(a, b, :ge)) | s]                      # f32.ge
  # ── f64 ──
  defp binop(0x99, [a | s]), do: [fabs(a, 64) | s]                                  # f64.abs
  defp binop(0x9A, [a | s]), do: [fneg(a, 64) | s]                                  # f64.neg
  defp binop(0x9F, [a | s]), do: [fsqrt(a, 64) | s]                                 # f64.sqrt
  defp binop(0xA0, [b, a | s]), do: [farith(a, b, :add, 64) | s]                    # f64.add
  defp binop(0xA1, [b, a | s]), do: [farith(a, b, :sub, 64) | s]                    # f64.sub
  defp binop(0xA2, [b, a | s]), do: [farith(a, b, :mul, 64) | s]                    # f64.mul
  defp binop(0xA3, [b, a | s]), do: [farith(a, b, :div, 64) | s]                    # f64.div
  defp binop(0xA4, [b, a | s]), do: [fminmax(a, b, :min, 64) | s]                   # f64.min
  defp binop(0xA5, [b, a | s]), do: [fminmax(a, b, :max, 64) | s]                   # f64.max
  defp binop(0x9B, [a | s]), do: [fround_unary(a, 64, &Float.ceil/1) | s]           # f64.ceil
  defp binop(0x9C, [a | s]), do: [fround_unary(a, 64, &Float.floor/1) | s]          # f64.floor
  defp binop(0x9D, [a | s]), do: [fround_unary(a, 64, fn x -> trunc(x) * 1.0 end) | s]  # f64.trunc
  defp binop(0x9E, [a | s]), do: [fround_unary(a, 64, &fnearest/1) | s]             # f64.nearest
  defp binop(0xA6, [b, a | s]), do: [fcopysign_nf(a, b, 64) | s]                    # f64.copysign
  defp binop(0x61, [b, a | s]), do: [bool(fcmp(a, b, :eq)) | s]                      # f64.eq
  defp binop(0x62, [b, a | s]), do: [bool(fcmp(a, b, :ne)) | s]                      # f64.ne
  defp binop(0x63, [b, a | s]), do: [bool(fcmp(a, b, :lt)) | s]                      # f64.lt
  defp binop(0x64, [b, a | s]), do: [bool(fcmp(a, b, :gt)) | s]                      # f64.gt
  defp binop(0x65, [b, a | s]), do: [bool(fcmp(a, b, :le)) | s]                      # f64.le
  defp binop(0x66, [b, a | s]), do: [bool(fcmp(a, b, :ge)) | s]                      # f64.ge
  # ── conversions (i32 ⇄ f32/f64) ──
  defp binop(0xA8, [a | s]), do: [ftrunc(a, -0x80000000, 0x7FFFFFFF) &&& @mask32 | s]  # i32.trunc_f32_s
  defp binop(0xA9, [a | s]), do: [ftrunc(a, 0, 0xFFFFFFFF) &&& @mask32 | s]             # i32.trunc_f32_u
  defp binop(0xAA, [a | s]), do: [ftrunc(a, -0x80000000, 0x7FFFFFFF) &&& @mask32 | s]  # i32.trunc_f64_s
  defp binop(0xAB, [a | s]), do: [ftrunc(a, 0, 0xFFFFFFFF) &&& @mask32 | s]             # i32.trunc_f64_u
  defp binop(0xB2, [a | s]), do: [f32r(s32(a) * 1.0) | s]                           # f32.convert_i32_s
  defp binop(0xB3, [a | s]), do: [f32r(a * 1.0) | s]                                # f32.convert_i32_u
  defp binop(0xB6, [a | s]), do: [f32r(a) | s]                                      # f32.demote_f64
  defp binop(0xB7, [a | s]), do: [s32(a) * 1.0 | s]                                 # f64.convert_i32_s
  defp binop(0xB8, [a | s]), do: [a * 1.0 | s]                                      # f64.convert_i32_u
  defp binop(0xBB, [a | s]), do: [a * 1.0 | s]                                      # f64.promote_f32
  # reinterpret = same bits, different type (no value change). decode_f handles non-finite bit patterns.
  defp binop(0xBC, [a | s]), do: [reinterpret_to_i(a, 32) | s]                      # i32.reinterpret_f32
  defp binop(0xBD, [a | s]), do: [reinterpret_to_i(a, 64) | s]                      # i64.reinterpret_f64
  defp binop(0xBE, [a | s]), do: [decode_f(a &&& @mask32, 32) | s]                  # f32.reinterpret_i32
  defp binop(0xBF, [a | s]), do: [decode_f(a &&& @mask64, 64) | s]                  # f64.reinterpret_i64
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
  defp binop(0x7F, [b, a | s]), do: [idiv(s64(a), s64(b), -0x8000000000000000) &&& @mask64 | s]  # i64.div_s
  defp binop(0x80, [b, a | s]), do: [udiv(a, b) &&& @mask64 | s]                     # i64.div_u
  defp binop(0x81, [b, a | s]), do: [irem(s64(a), s64(b)) &&& @mask64 | s]           # i64.rem_s
  defp binop(0x82, [b, a | s]), do: [urem(a, b) &&& @mask64 | s]                     # i64.rem_u
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
  defp binop(0xB0, [a | s]), do: [ftrunc(a, -0x8000000000000000, 0x7FFFFFFFFFFFFFFF) &&& @mask64 | s]  # i64.trunc_f64_s
  defp binop(0xB1, [a | s]), do: [ftrunc(a, 0, 0xFFFFFFFFFFFFFFFF) &&& @mask64 | s]                     # i64.trunc_f64_u

  # non-saturating float→int truncation: traps on NaN/Inf (non-finite, a {:nonfinite,_,_} stack value)
  # and on out-of-range — exactly the spec's "invalid conversion" / "integer overflow" traps.
  defp ftrunc(a, lo, hi) when is_float(a) do
    t = trunc(a)
    if t < lo or t > hi, do: trap!(:conversion_overflow), else: t
  end

  defp ftrunc(_a, _lo, _hi), do: trap!(:invalid_conversion)
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
  # round to single precision; an f32-overflowing magnitude becomes ±Inf (decode_f → {:nonfinite,_,32})
  # rather than raising on the (non-finite) bit pattern.
  defp f32r({:nonfinite, _, _} = x), do: x
  defp f32r(x), do: decode_f(:binary.decode_unsigned(<<x::float-32-little>>, :little), 32)

  # round to nearest integer, ties to EVEN (wasm f.nearest), as a float
  defp fnearest(a) do
    f = Float.floor(a)
    case a - f do
      d when d < 0.5 -> f
      d when d > 0.5 -> f + 1.0
      _ -> if rem(trunc(f), 2) == 0, do: f, else: f + 1.0
    end
  end

  # magnitude of `a`, sign of `b` (signed-zero edge ignored — BEAM has no -0.0 distinction here)
  defp fcopysign(a, b), do: if(b < 0, do: -abs(a), else: abs(a))

  # non-finite-safe rounding ops: ceil/floor/trunc/nearest of ±Inf = ±Inf, of NaN = NaN; finite via `f`.
  defp fround_unary(a, size, f) do
    case fclass(a) do
      {:fin, x} -> fround(f.(x), size)
      {:inf, s} -> finf(size, s)
      :nan -> fnan(size)
    end
  end

  # copysign with non-finite operands: magnitude of `a` (incl. Inf/NaN) carrying the sign of `b`.
  defp fcopysign_nf(a, b, size) do
    bsign = case fclass(b) do
      {:inf, s} -> s
      {:fin, y} -> if(y < 0.0, do: -1, else: 1)
      :nan -> 1
    end

    case fclass(a) do
      {:fin, x} -> fround(if(bsign < 0, do: -abs(x), else: abs(x)), size)
      {:inf, _} -> finf(size, bsign)
      :nan -> fnan(size)
    end
  end

  # decode raw IEEE-754 bits → a BEAM float when finite, else a non-finite placeholder (BEAM has no NaN/Inf)
  # a float's raw bit pattern as an unsigned integer (non-finite floats are carried as {:nonfinite, bits, _})
  defp reinterpret_to_i({:nonfinite, bits, _}, _size), do: bits
  defp reinterpret_to_i(a, 32) when is_float(a), do: (<<i::32-little>> = <<a::float-32-little>>; i)
  defp reinterpret_to_i(a, 64) when is_float(a), do: (<<i::64-little>> = <<a::float-64-little>>; i)

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
    bin = for(i <- 0..(n - 1)//1, do: mget(mem, addr + i)) |> :erlang.list_to_binary()
    # decode via the bit pattern so non-finite values (±Inf/NaN) survive as {:nonfinite, bits, size}
    decode_f(:binary.decode_unsigned(bin, :little), n * 8)
  end

  defp fstore(mem, addr, v, n) do
    bin =
      case v do
        {:nonfinite, bits, _} -> <<bits::size(n * 8)-little>>
        _ when n == 4 -> <<v::float-32-little>>
        _ -> <<v::float-64-little>>
      end

    bin |> :binary.bin_to_list() |> Enum.with_index() |> Enum.each(fn {b, i} -> mput(mem, addr + i, b) end)
  end

  # ── IEEE-754 special-value arithmetic (wb-8mdz.3) ────────────────────────────────────────────────
  # BEAM floats cannot represent ±Inf/NaN/-0; finite values stay Elixir floats, non-finite ones are
  # carried as {:nonfinite, bits, size} (the same shape decode_f / reinterpret already use). Every float
  # op routes through these so a div-by-zero / overflow / sqrt(-1) yields the right special instead of
  # raising ArithmeticError.
  @inf_bits %{64 => 0x7FF0000000000000, 32 => 0x7F800000}
  @ninf_bits %{64 => 0xFFF0000000000000, 32 => 0xFF800000}
  @nan_bits %{64 => 0x7FF8000000000000, 32 => 0x7FC00000}

  defp finf(size, 1), do: {:nonfinite, @inf_bits[size], size}
  defp finf(size, -1), do: {:nonfinite, @ninf_bits[size], size}
  defp fnan(size), do: {:nonfinite, @nan_bits[size], size}

  # classify an operand into {:fin, float} | {:inf, +1|-1} | :nan
  defp fclass(x) when is_float(x), do: {:fin, x}

  defp fclass({:nonfinite, bits, size}) do
    {ew, mmask} = if size == 64, do: {0x7FF, 0xFFFFFFFFFFFFF}, else: {0xFF, 0x7FFFFF}
    sbit = if size == 64, do: 63, else: 31
    ebit = if size == 64, do: 52, else: 23
    exp = (bits >>> ebit) &&& ew
    mant = bits &&& mmask
    sign = if ((bits >>> sbit) &&& 1) == 1, do: -1, else: 1

    cond do
      exp == ew and mant == 0 -> {:inf, sign}
      exp == ew -> :nan
      true -> {:fin, decode_f(bits, size)}
    end
  end

  defp fsignf(x) when is_float(x), do: if(x < 0.0, do: -1, else: 1)
  defp fround(r, 32), do: f32r(r)
  defp fround(r, 64), do: r

  defp farith(a, b, op, size) do
    case {fclass(a), fclass(b)} do
      {:nan, _} -> fnan(size)
      {_, :nan} -> fnan(size)
      {ca, cb} -> farith2(ca, cb, op, size)
    end
  end

  defp farith2({:fin, x}, {:fin, y}, op, size) do
    try do
      fround(
        case op do
          :add -> x + y
          :sub -> x - y
          :mul -> x * y
          :div -> x / y
        end,
        size
      )
    rescue
      ArithmeticError ->
        # div-by-zero or overflow → the IEEE special with the correct sign
        case op do
          :div -> if x == 0.0, do: fnan(size), else: finf(size, fsignf(x) * fsignf(y))
          :mul -> finf(size, fsignf(x) * fsignf(y))
          _ -> finf(size, fsignf(x))
        end
    end
  end

  defp farith2({:inf, sa}, {:inf, sb}, op, size) do
    case op do
      :add -> if sa == sb, do: finf(size, sa), else: fnan(size)
      :sub -> if sa != sb, do: finf(size, sa), else: fnan(size)
      :mul -> finf(size, sa * sb)
      :div -> fnan(size)
    end
  end

  defp farith2({:inf, sa}, {:fin, y}, op, size) do
    case op do
      :mul -> if y == 0.0, do: fnan(size), else: finf(size, sa * fsignf(y))
      :div -> finf(size, sa * fsignf(y))
      _ -> finf(size, sa)
    end
  end

  defp farith2({:fin, x}, {:inf, sb}, op, size) do
    case op do
      :add -> finf(size, sb)
      :sub -> finf(size, -sb)
      :mul -> if x == 0.0, do: fnan(size), else: finf(size, fsignf(x) * sb)
      :div -> fround(0.0, size)
    end
  end

  # comparisons — NaN is unordered (only `ne` is true); otherwise a 3-way compare over the classified forms
  # (±Inf handled explicitly, since Elixir term order would mis-rank a float vs an atom sentinel).
  defp fcmp(a, b, op) do
    ca = fclass(a)
    cb = fclass(b)

    if ca == :nan or cb == :nan do
      op == :ne
    else
      c = fcompare(ca, cb)

      case op do
        :eq -> c == 0
        :ne -> c != 0
        :lt -> c < 0
        :gt -> c > 0
        :le -> c <= 0
        :ge -> c >= 0
      end
    end
  end

  defp fcompare({:fin, x}, {:fin, y}), do: cond(do: (x < y -> -1; x > y -> 1; true -> 0))
  defp fcompare({:inf, s}, {:inf, t}), do: cond(do: (s == t -> 0; s < t -> -1; true -> 1))
  defp fcompare({:inf, 1}, _), do: 1
  defp fcompare({:inf, -1}, _), do: -1
  defp fcompare(_, {:inf, 1}), do: -1
  defp fcompare(_, {:inf, -1}), do: 1

  defp fminmax(a, b, which, size) do
    case {fclass(a), fclass(b)} do
      {:nan, _} -> fnan(size)
      {_, :nan} -> fnan(size)
      _ -> if fcmp(a, b, if(which == :min, do: :le, else: :ge)), do: a, else: b
    end
  end

  defp fabs(a, size) do
    case fclass(a) do
      {:fin, x} -> fround(abs(x), size)
      {:inf, _} -> finf(size, 1)
      :nan -> fnan(size)
    end
  end

  defp fneg(a, size) do
    case fclass(a) do
      {:fin, x} -> fround(-x, size)
      {:inf, s} -> finf(size, -s)
      :nan -> fnan(size)
    end
  end

  defp fsqrt(a, size) do
    case fclass(a) do
      {:fin, x} when x < 0.0 -> fnan(size)
      {:fin, x} -> fround(:math.sqrt(x), size)
      {:inf, 1} -> finf(size, 1)
      {:inf, -1} -> fnan(size)
      :nan -> fnan(size)
    end
  end

  # copy n bytes within memory, src->dst, overlap-safe (forward when dst<=src, else backward)
  defp mem_copy(mem, dst, src, n) when dst <= src,
    do: for(i <- 0..(n - 1)//1, do: mput(mem, dst + i, mget(mem, src + i)))

  defp mem_copy(mem, dst, src, n),
    do: for(i <- (n - 1)..0//-1, do: mput(mem, dst + i, mget(mem, src + i)))

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
    Enum.reduce(0..(n - 1), 0, fn i, acc -> acc ||| (mget(mem, addr + i) <<< (i * 8)) end)
  end

  defp store(mem, addr, val, n) do
    for i <- 0..(n - 1), do: mput(mem, addr + i, (val >>> (i * 8)) &&& 0xFF)
    :ok
  end

  # Linear memory is PACKED: one 64-bit `:atomics` slot holds 8 consecutive bytes (little-endian
  # within the word), so the backing is 8x smaller than one-slot-per-byte. Byte access is a
  # read-modify-write of the containing word — safe without atomicity since one guest = one process.
  defp mget(mem, addr) do
    w = :atomics.get(mem, (addr >>> 3) + 1)
    (w >>> ((addr &&& 7) * 8)) &&& 0xFF
  end

  defp mput(mem, addr, byte) do
    idx = (addr >>> 3) + 1
    sh = (addr &&& 7) * 8
    w = :atomics.get(mem, idx)
    w = ((w &&& bnot(0xFF <<< sh)) ||| ((byte &&& 0xFF) <<< sh)) &&& @mask64
    :atomics.put(mem, idx, w)
  end

  # a small bounded fuel counter for const-expression evaluation (global init / element offsets) —
  # these are tiny + trusted, but still flow through the fuel-charging `run/4`.
  defp cfuel do
    f = :atomics.new(1, signed: true)
    :atomics.put(f, 1, 1_000_000)
    f
  end

  # ── traps ───────────────────────────────────────────────────────────────────────────────────────
  # Integer division: wasm traps on a zero divisor and on the single signed-overflow case
  # (INT_MIN / -1). `smin` is the type's signed minimum; the `idiv(a, -1, a)` head matches when the
  # dividend equals it. rem_s has no overflow trap (INT_MIN % -1 == 0, which Erlang already yields).
  defp idiv(_a, 0, _smin), do: trap!(:div_by_zero)
  defp idiv(a, -1, a), do: trap!(:int_overflow)
  defp idiv(a, b, _smin), do: div(a, b)
  defp udiv(_a, 0), do: trap!(:div_by_zero)
  defp udiv(a, b), do: div(a, b)
  defp irem(_a, 0), do: trap!(:div_by_zero)
  defp irem(a, b), do: rem(a, b)
  defp urem(_a, 0), do: trap!(:div_by_zero)
  defp urem(a, b), do: rem(a, b)

  # Guest memory access is bounds-checked against the LOGICAL memory size (pages × 64KB), not the
  # over-allocated atomics cap: an access past `memory.size` traps, exactly as the spec requires (and
  # the transpiler will lower to the same trap, so the oracle can compare). Host-internal `store/4`
  # writes (iovecs/argv/stat structs) stay unchecked — they're trusted runtime bookkeeping.
  defp bounds!(rt, addr, n) do
    limit = :atomics.get(rt.mem_pages, 1) * 65536
    if addr < 0 or addr + n > limit, do: trap!(:out_of_bounds)
  end

  defp gload(rt, addr, n), do: (bounds!(rt, addr, n); load(wmem(), addr, n))
  defp gstore(rt, addr, v, n), do: (bounds!(rt, addr, n); store(wmem(), addr, v, n))
  defp gfload(rt, addr, n), do: (bounds!(rt, addr, n); fload(wmem(), addr, n))
  defp gfstore(rt, addr, v, n), do: (bounds!(rt, addr, n); fstore(wmem(), addr, v, n))
  defp gvload(rt, addr), do: (bounds!(rt, addr, 16); vload(wmem(), addr))
  defp gvstore(rt, addr, v), do: (bounds!(rt, addr, 16); vstore(wmem(), addr, v))
end

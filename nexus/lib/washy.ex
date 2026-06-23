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

  defstruct types: [], funcs: [], exports: %{}, code: [], mem: nil

  @typedoc "A decoded module."
  @type t :: %__MODULE__{}

  @mask32 0xFFFFFFFF

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

  # 5 = memory: vec of limits (wasm MVP has one memory). limit = flag(0|1) then min[, max] in 64KB pages.
  defp section(5, content, mod) do
    {mems, _} = vec(content, &limits/1)
    %{mod | mem: List.first(mems)}
  end

  # sections we don't need yet (global/import/data/custom/…) are skipped
  defp section(_id, _content, mod), do: mod

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

  defp parse_op(0x41, rest), do: ({v, r} = sleb(rest); {{:i32_const, v}, r})
  defp parse_op(0x20, rest), do: ({i, r} = uleb(rest); {{:local_get, i}, r})
  defp parse_op(0x21, rest), do: ({i, r} = uleb(rest); {{:local_set, i}, r})
  defp parse_op(0x22, rest), do: ({i, r} = uleb(rest); {{:local_tee, i}, r})
  defp parse_op(0x10, rest), do: ({f, r} = uleb(rest); {{:call, f}, r})
  defp parse_op(0x0C, rest), do: ({n, r} = uleb(rest); {{:br, n}, r})
  defp parse_op(0x0D, rest), do: ({n, r} = uleb(rest); {{:br_if, n}, r})
  defp parse_op(0x0F, rest), do: {{:return}, rest}
  defp parse_op(0x1A, rest), do: {{:drop}, rest}
  defp parse_op(0x00, rest), do: {{:unreachable}, rest}
  defp parse_op(0x01, rest), do: {{:nop}, rest}
  defp parse_op(0x28, rest), do: ({o, r} = memarg(rest); {{:i32_load, o}, r})
  defp parse_op(0x2D, rest), do: ({o, r} = memarg(rest); {{:i32_load8u, o}, r})
  defp parse_op(0x36, rest), do: ({o, r} = memarg(rest); {{:i32_store, o}, r})
  defp parse_op(0x3A, rest), do: ({o, r} = memarg(rest); {{:i32_store8, o}, r})
  defp parse_op(0x3F, <<_, rest::binary>>), do: {{:memory_size}, rest}
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
    rt = %{mod: mod, mem: new_mem(mod.mem)}
    invoke(rt, Map.fetch!(mod.exports, name), args)
  end

  # one `:atomics` slot per byte (simple + correct; pack-to-words is a later optimization). nil = no memory.
  defp new_mem(nil), do: nil
  defp new_mem({min, _max}), do: :atomics.new(max(1, min) * 65536, signed: false)

  # Invoke local function `fidx`: zero-extend declared locals after the args, run the structured body.
  defp invoke(rt, fidx, args) do
    {nlocals, instrs} = Enum.at(rt.mod.code, fidx)
    locals = (args ++ List.duplicate(0, nlocals)) |> List.to_tuple()
    {_sig, stack, _l} = run(instrs, [], locals, rt)
    case stack do
      [top | _] -> top
      [] -> nil
    end
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

  defp step({:i32_const, v}, stack, l, _rt), do: {:next, [v &&& @mask32 | stack], l}
  defp step({:local_get, i}, stack, l, _rt), do: {:next, [elem(l, i) | stack], l}
  defp step({:local_set, i}, [v | stack], l, _rt), do: {:next, stack, put_elem(l, i, v)}
  defp step({:local_tee, i}, [v | _] = stack, l, _rt), do: {:next, stack, put_elem(l, i, v)}

  defp step({:call, f}, stack, l, rt) do
    {params, _} = Enum.at(rt.mod.types, Enum.at(rt.mod.funcs, f))
    {args, stack} = Enum.split(stack, length(params))
    {:next, [invoke(rt, f, Enum.reverse(args)) | stack], l}
  end

  defp step({:i32_load, o}, [a | s], l, rt), do: {:next, [load(rt.mem, a + o, 4) | s], l}
  defp step({:i32_load8u, o}, [a | s], l, rt), do: {:next, [load(rt.mem, a + o, 1) | s], l}
  defp step({:i32_store, o}, [v, a | s], l, rt), do: (store(rt.mem, a + o, v, 4); {:next, s, l})
  defp step({:i32_store8, o}, [v, a | s], l, rt), do: (store(rt.mem, a + o, v, 1); {:next, s, l})
  defp step({:memory_size}, stack, l, rt), do: {:next, [div(:atomics.info(rt.mem).size, 65536) | stack], l}

  defp step({:op, op}, stack, l, _rt), do: {:next, binop(op, stack), l}

  # ── pure stack ops: arithmetic + comparisons. `[b, a | s]` — a pushed first, b on top. ──
  defp binop(0x6A, [b, a | s]), do: [(a + b) &&& @mask32 | s]                       # i32.add
  defp binop(0x6B, [b, a | s]), do: [(a - b) &&& @mask32 | s]                       # i32.sub
  defp binop(0x6C, [b, a | s]), do: [(a * b) &&& @mask32 | s]                       # i32.mul
  defp binop(0x6E, [b, a | s]), do: [div(a, b) &&& @mask32 | s]                     # i32.div_u
  defp binop(0x70, [b, a | s]), do: [rem(a, b) &&& @mask32 | s]                     # i32.rem_u
  defp binop(0x71, [b, a | s]), do: [a &&& b | s]                                   # i32.and
  defp binop(0x72, [b, a | s]), do: [a ||| b | s]                                   # i32.or
  defp binop(0x73, [b, a | s]), do: [bxor(a, b) | s]                                # i32.xor
  defp binop(0x74, [b, a | s]), do: [(a <<< (b &&& 31)) &&& @mask32 | s]            # i32.shl
  defp binop(0x76, [b, a | s]), do: [a >>> (b &&& 31) | s]                          # i32.shr_u
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
  defp binop(op, _), do: raise("washy: unimplemented stack op 0x#{Integer.to_string(op, 16)}")

  defp bool(true), do: 1
  defp bool(false), do: 0
  defp s32(x) when x >= 0x80000000, do: x - 0x100000000
  defp s32(x), do: x

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

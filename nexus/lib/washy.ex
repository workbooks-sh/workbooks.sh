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
    {{nlocals, code}, rest2}
  end

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

  # Invoke local function `fidx`: zero-extend declared locals after the args, run the body.
  defp invoke(rt, fidx, args) do
    {nlocals, body} = Enum.at(rt.mod.code, fidx)
    locals = (args ++ List.duplicate(0, nlocals)) |> List.to_tuple()
    {stack, _} = exec(body, [], locals, rt)
    case stack do
      [top | _] -> top
      [] -> nil
    end
  end

  # The stack machine. `exec(code, operand_stack, locals_tuple, runtime) -> {stack, leftover_code}`.
  defp exec(<<>>, stack, _l, _rt), do: {stack, <<>>}
  defp exec(<<0x0B, rest::binary>>, stack, _l, _rt), do: {stack, rest}        # end
  defp exec(<<0x0F, _::binary>>, stack, _l, _rt), do: {stack, <<>>}           # return

  defp exec(<<0x1A, rest::binary>>, [_ | stack], l, rt), do: exec(rest, stack, l, rt)   # drop

  defp exec(<<0x20, rest::binary>>, stack, l, rt) do                          # local.get
    {i, rest} = uleb(rest)
    exec(rest, [elem(l, i) | stack], l, rt)
  end

  defp exec(<<0x21, rest::binary>>, [v | stack], l, rt) do                    # local.set
    {i, rest} = uleb(rest)
    exec(rest, stack, put_elem(l, i, v), rt)
  end

  defp exec(<<0x22, rest::binary>>, [v | _] = stack, l, rt) do                # local.tee
    {i, rest} = uleb(rest)
    exec(rest, stack, put_elem(l, i, v), rt)
  end

  defp exec(<<0x41, rest::binary>>, stack, l, rt) do                          # i32.const
    {v, rest} = sleb(rest)
    exec(rest, [v &&& @mask32 | stack], l, rt)
  end

  defp exec(<<0x10, rest::binary>>, stack, l, rt) do                          # call
    {fidx, rest} = uleb(rest)
    {nparams, _} = Enum.at(rt.mod.types, Enum.at(rt.mod.funcs, fidx))
    n = length(nparams)
    {args, stack} = Enum.split(stack, n)
    result = invoke(rt, fidx, Enum.reverse(args))
    exec(rest, [result | stack], l, rt)
  end

  # ── linear memory (little-endian) ── effective address = popped addr + the memarg `offset` immediate
  defp exec(<<0x28, rest::binary>>, [addr | stack], l, rt) do                 # i32.load
    {off, rest} = memarg(rest)
    exec(rest, [load(rt.mem, addr + off, 4) | stack], l, rt)
  end

  defp exec(<<0x2D, rest::binary>>, [addr | stack], l, rt) do                 # i32.load8_u
    {off, rest} = memarg(rest)
    exec(rest, [load(rt.mem, addr + off, 1) | stack], l, rt)
  end

  defp exec(<<0x36, rest::binary>>, [val, addr | stack], l, rt) do            # i32.store
    {off, rest} = memarg(rest)
    store(rt.mem, addr + off, val, 4)
    exec(rest, stack, l, rt)
  end

  defp exec(<<0x3A, rest::binary>>, [val, addr | stack], l, rt) do            # i32.store8
    {off, rest} = memarg(rest)
    store(rt.mem, addr + off, val, 1)
    exec(rest, stack, l, rt)
  end

  defp exec(<<0x3F, rest::binary>>, stack, l, rt) do                          # memory.size (pages)
    <<_reserved, rest::binary>> = rest
    pages = div(:atomics.info(rt.mem).size, 65536)
    exec(rest, [pages | stack], l, rt)
  end

  # binary i32 ops: pop b, a (a was pushed first), push f(a,b)
  for {op, fun} <- [{0x6A, :+}, {0x6B, :-}, {0x6C, :*}] do
    defp exec(<<unquote(op), rest::binary>>, [b, a | stack], l, rt),
      do: exec(rest, [(Kernel.unquote(fun)(a, b)) &&& @mask32 | stack], l, rt)
  end

  defp exec(<<0x71, rest::binary>>, [b, a | stack], l, rt), do: exec(rest, [a &&& b | stack], l, rt)  # i32.and
  defp exec(<<0x72, rest::binary>>, [b, a | stack], l, rt), do: exec(rest, [a ||| b | stack], l, rt)  # i32.or
  defp exec(<<0x73, rest::binary>>, [b, a | stack], l, rt), do: exec(rest, [bxor(a, b) | stack], l, rt) # i32.xor

  # unknown opcode — surface it loudly so we know exactly what to implement next
  defp exec(<<op, _::binary>>, _stack, _l, _rt), do: raise("washy: unimplemented opcode 0x#{Integer.to_string(op, 16)}")

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

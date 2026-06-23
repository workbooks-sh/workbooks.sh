defmodule Nexus.Washy.Transpile do
  @moduledoc """
  **Washy's wasm→BEAM transpiler — spike v0.** The second execution backend: instead of *interpreting*
  the structured instruction tree, it *compiles* a wasm function to a real BEAM function (Erlang
  abstract forms → `:compile.forms` → `:code.load_binary`), so it runs on the BeamAsm JIT at native-ish
  speed while inheriting the same isolation (it's still ordinary BEAM code in a process).

  The key idea that makes this tractable: a wasm function is already *structured* (no arbitrary gotos),
  and its operand stack is a compile-time artifact — so we **compile the stack away**. We fold the
  instruction list maintaining a stack of Erlang *expressions* (not values); `local.get` pushes a
  parameter var, `i32.const` pushes a literal, `i32.add` pops two expression-operands and pushes
  `(A + B) band 16#FFFFFFFF`. The top of the final stack is the function's return expression. No
  operand stack survives to runtime — it became the shape of the generated AST (SSA-ish).

  **v0 scope (deliberately narrow):** straight-line integer functions — `local.get`, `i32.const`, and
  the wrapping integer binops (`add/sub/mul/and/or/xor/shl/shr_*`). No memory, calls, or control flow
  yet (those lower to recursion / host calls in later increments). Anything outside scope returns
  `{:error, {:unsupported, op}}` — never wrong code. Correctness is gated by the differential oracle:
  the transpiled function must produce the SAME outcome as the interpreter on every input.
  """
  @mask32 0xFFFFFFFF

  @doc """
  Compile exported function `name` to a native BEAM function. Returns `{:ok, fun}` where `fun` takes
  the argument LIST (e.g. `fun.([3, 4])`), or `{:error, {:unsupported, op}}` if it falls outside v0.
  """
  def compile(mod, name) do
    {arity, nlocals, instrs} = Nexus.Washy.function_body(mod, name)

    if nlocals != 0 do
      {:error, {:unsupported, :locals}}
    else
      try do
        body = lower(instrs, arity)
        mname = :"washy_jit_#{System.unique_integer([:positive])}"

        forms = [
          {:attribute, 1, :module, mname},
          {:attribute, 1, :export, [{:run, arity}]},
          {:function, 1, :run, arity, [{:clause, 1, params(arity), [], [body]}]}
        ]

        {:ok, ^mname, bin} = :compile.forms(forms, [:return_errors])
        {:module, ^mname} = :code.load_binary(mname, ~c"nofile", bin)
        {:ok, fn args -> apply(mname, :run, args) end}
      catch
        {:unsupported, op} -> {:error, {:unsupported, op}}
      end
    end
  end

  # fold the instruction list into a single return expression (stack-as-AST)
  defp lower(instrs, arity) do
    locals = Map.new(0..(arity - 1)//1, fn i -> {i, var(i)} end)

    case Enum.reduce(instrs, [], &lower_op(&1, &2, locals)) do
      [top | _] -> top
      [] -> {:integer, 1, 0}
    end
  end

  defp lower_op({:local_get, i}, stack, locals), do: [Map.fetch!(locals, i) | stack]
  defp lower_op({:i32_const, v}, stack, _), do: [{:integer, 1, v} | stack]

  defp lower_op({:op, opcode}, [b, a | stack], _) do
    [mask32(binop(opcode, a, b)) | stack]
  end

  defp lower_op(other, _stack, _), do: throw({:unsupported, other})

  # wasm integer binop → Erlang abstract-format expression (result is masked to 32 bits by the caller)
  defp binop(0x6A, a, b), do: {:op, 1, :+, a, b}
  defp binop(0x6B, a, b), do: {:op, 1, :-, a, b}
  defp binop(0x6C, a, b), do: {:op, 1, :*, a, b}
  defp binop(0x71, a, b), do: {:op, 1, :band, a, b}
  defp binop(0x72, a, b), do: {:op, 1, :bor, a, b}
  defp binop(0x73, a, b), do: {:op, 1, :bxor, a, b}
  # shifts: the count is mod 32 (wasm), then the result is masked back to 32 bits by the caller
  defp binop(0x74, a, b), do: {:op, 1, :bsl, a, {:op, 1, :band, b, {:integer, 1, 31}}}
  defp binop(0x76, a, b), do: {:op, 1, :bsr, a, {:op, 1, :band, b, {:integer, 1, 31}}}
  defp binop(op, _a, _b), do: throw({:unsupported, {:op, op}})

  defp mask32(expr), do: {:op, 1, :band, expr, {:integer, 1, @mask32}}
  defp params(arity), do: Enum.map(0..(arity - 1)//1, &var/1)
  defp var(i), do: {:var, 1, :"A#{i}"}
end

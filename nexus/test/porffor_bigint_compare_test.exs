defmodule Nexus.PorfforBigintCompareTest do
  @moduledoc """
  **BigInt comparison regression gate (ASM lane).**

  Porffor carries a bigint as an f64: inline when `|v| < 2^51` (the value IS the number), else a heap object
  reached via a `realPtr + 2^51` offset pointer (sign byte @0, u16 limb-count @2, base-2^32 limbs MSB-first
  @4). Binary ops used to go straight through the f64 `operatorOpcode` path — correct *by coincidence* for
  small inline bigints, but a heap bigint is a tagged pointer, so `f64 ===` compared pointer IDENTITY (two
  equal large literals were `false`) and `<`/`>` compared pointer addresses.

  This locks bigint comparison (`=== == !== != < > <= >=`) wired to the digit-aware runtime compare. The fix
  had four interlocking parts, all required:
    1. `precompile.js` valtypeOverrides — the bigint ops take/return f64 (their values are f64 up to 2^53);
       without this they default to i32-valtype, truncating the value and overflowing the 2^51 boundary
       constant to an out-of-range `i32.const` that traps at runtime.
    2. `__Porffor_bigint_cmp` — three-way sign-magnitude compare WITHOUT subtraction (clamp leading-zero
       limbs → effective length, signed-zero-normalized sign so `-0n === 0n`, then unsigned limb compare).
    3. codegen dispatch for both-statically-bigint operands, pushing the (value, type) pair ABI each builtin
       expects (value f64 + type i32) — pushing only the values made the callee read a non-existent local.
    4. `__Porffor_bigint_inlineToDigitForm` — returns the OFFSET pointer (so callers' `x -= 2^51` recovers
       the real pointer) and splits `|n|` into high/low limbs (an inline value can exceed 2^32).

  Arithmetic on heap bigints (`+ - * /`) is a separate slice (it needs the digit add/mul/div bodies); small
  arithmetic stays correct on the f64 path. Every case here asserts byte-equality with `node`.
  """
  use ExUnit.Case, async: false

  @moduletag :porffor

  @big "123456789012345678901234567890n"
  @big1 "123456789012345678901234567891n"

  # {name, source, expected-stdout (what `node` prints, trimmed)}
  @corpus [
    # small inline
    {"small_eq", "console.log(2n===2n)", "true"},
    {"small_ne", "console.log(2n!==3n)", "true"},
    {"small_lt", "console.log(2n<3n)", "true"},
    {"small_gt", "console.log(5n>3n)", "true"},
    # large heap, same magnitude
    {"large_eq_t", "console.log(9007199254740995n===9007199254740995n)", "true"},
    {"large_eq_f", "console.log(9007199254740995n===9007199254740996n)", "false"},
    {"large_lt", "console.log(9007199254740995n<9007199254740996n)", "true"},
    {"large_ge", "console.log(9007199254740995n>=9007199254740995n)", "true"},
    {"large_le", "console.log(9007199254740995n<=9007199254740996n)", "true"},
    # huge (30-digit) literals
    {"huge_eq", "console.log(#{@big}===#{@big})", "true"},
    {"huge_lt", "console.log(#{@big}<#{@big1})", "true"},
    {"huge_ne", "console.log(#{@big}!==#{@big1})", "true"},
    # mixed inline/heap (exercises inlineToDigitForm)
    {"mix_lt", "console.log(2n<9007199254740995n)", "true"},
    {"mix_gt", "console.log(9007199254740995n>2n)", "true"},
    {"mix_eq_f", "console.log(2n===9007199254740995n)", "false"},
    # zero + negative-zero normalization (-0n must compare equal to 0n)
    {"zero_eq", "console.log(0n===0n)", "true"},
    {"negzero_eq", "console.log(-0n===0n)", "true"},
    # negatives
    {"neg_small", "console.log(-5n<-3n)", "true"},
    {"neg_ge", "console.log(-3n>=-5n)", "true"},
    {"neg_large_lt", "console.log(-9007199254740996n<-9007199254740995n)", "true"},
    {"neg_vs_pos", "console.log((-9007199254740995n)<9007199254740995n)", "true"}
  ]

  setup_all do
    if File.regular?(Nexus.Compilers.Js.Porffor.porf_entry()),
      do: :ok,
      else: {:skip, "porffor absent"}
  end

  defp run_asm(src) do
    with {:ok, wasm} <- Nexus.Compilers.Js.Porffor.compile(src),
         {:ok, mod} <- TinyLasers.Wasm.decode(wasm) do
      task =
        Task.async(fn ->
          Process.put(:porffor_out, [])
          emit = fn s -> Process.put(:porffor_out, [s | Process.get(:porffor_out, [])]) end

          Process.put(:tl_imports, %{
            "a" => fn [v] -> emit.(to_string(v)); nil end,
            "b" => fn [v] -> emit.(<<trunc(v)::utf8>>); nil end,
            "c" => fn [] -> 0.0 end,
            "d" => fn [] -> 0.0 end
          })

          try do
            TinyLasers.Wasm.call_io(mod, "m", [], fuel: 50_000_000, transpile: true)
            out = Process.get(:porffor_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
            {:ok, out |> String.replace(~r/\e\[[0-9;]*m/, "") |> String.trim()}
          rescue
            e -> {:error, Exception.message(e)}
          catch
            :throw, v -> {:error, inspect(v)}
          end
        end)

      Task.await(task, 90_000)
    end
  end

  for {name, src, want} <- @corpus do
    @tag :bigint
    test "bigint compare: #{name} (ASM ≡ node)" do
      assert {:ok, unquote(want)} == run_asm(unquote(src)),
             "#{unquote(name)}: ASM lane != node golden #{inspect(unquote(want))}"
    end
  end
end

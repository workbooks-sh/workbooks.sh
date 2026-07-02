defmodule Nexus.PorfforBigintArithTest do
  @moduledoc """
  **BigInt arithmetic + toString regression gate (ASM lane).**

  Locks the full heap-bigint runtime — `+ - * / %` and a digit-exact `toString` — wired through codegen for
  both-statically-bigint operands. Porffor carries a bigint as an f64 (inline when `|v| < 2^51`, else a
  `realPtr + 2^51` offset pointer to sign-magnitude base-2^32 MSB-first limbs). The ops were empty/broken
  stubs that the operator path never even called (it used f64 opcodes, correct only by coincidence for small
  inline values). This rebuild fixed a cascade of bugs, each pinned by a case below:

    * **f64→i32 store saturation** — a u32 limb >= 2^31 written into an i32[] saturated at 2147483647
      (`fromString`/`add`/`fromNumber`/`inlineToDigitForm`); now stored as its signed value. (e18/e21/huge.)
    * **i32 overflow in fromString's divmod** (`BASE = 2^32` as i32 = 0). Now f64.
    * **diff-sign subtraction magnitude** — per-limb `a-b` only works when `|a| >= |b|`; otherwise it wrapped
      (`0n - big` gave garbage). Now subtracts smaller magnitude from larger. (neg/cross.)
    * **`>>>` on an f64 limb >= 2^31** misbehaved in binary long division; the dividend is kept as i32 bit
      patterns. (div x/x, 1e24/1e12.)
    * **division remainder array** needed one extra limb for the pre-subtract left shift.

  `mul` is 16-bit half-limb FOIL accumulated in f64 then normalized; `div`/`rem` are binary long division
  (quotient truncates toward zero, remainder takes the dividend's sign). Every case is byte-equal to `node`.
  """
  use ExUnit.Case, async: false

  @moduletag :porffor

  @a "123456789012345678901234567890n"

  # {name, source, expected-stdout (what `node` prints, trimmed)}
  @corpus [
    # toString — the verification oracle; spans 2/3/4/5-limb + 1e18/1e21 (the saturation boundary)
    {"ts_small", "console.log((255n).toString())", "255"},
    {"ts_2limb", "console.log((9007199254740995n).toString())", "9007199254740995"},
    {"ts_e18", "console.log((1000000000000000000n).toString())", "1000000000000000000"},
    {"ts_e21", "console.log((1000000000000000000000n).toString())", "1000000000000000000000"},
    {"ts_pow2_128", "console.log((340282366920938463463374607431768211456n).toString())", "340282366920938463463374607431768211456"},
    {"ts_30dig", "console.log(#{@a}.toString())", "123456789012345678901234567890"},
    {"ts_neg", "console.log((-#{@a}).toString())", "-123456789012345678901234567890"},
    # add / sub
    {"add_small", "console.log((2n+3n).toString())", "5"},
    {"add_carry", "console.log((4294967295n+1n).toString())", "4294967296"},
    {"add_heap", "console.log((9007199254740990n+5n).toString())", "9007199254740995"},
    {"add_huge", "console.log((#{@a}+#{@a}).toString())", "246913578024691357802469135780"},
    {"sub_borrow", "console.log((1000000000000000000000n-1n).toString())", "999999999999999999999"},
    {"sub_neg_result", "console.log((2n-5n).toString())", "-3"},
    {"sub_zero_minus_big", "console.log((0n-#{@a}).toString())", "-123456789012345678901234567890"},
    {"sub_cross_zero", "console.log((5n-9007199254740995n).toString())", "-9007199254740990"},
    # mul
    {"mul_small", "console.log((2n*3n).toString())", "6"},
    {"mul_1limb", "console.log((123456789n*987654321n).toString())", "121932631112635269"},
    {"mul_2limb", "console.log((1000000000000n*1000000000000n).toString())", "1000000000000000000000000"},
    {"mul_neg", "console.log(((-5n)*7n).toString())", "-35"},
    {"mul_negneg", "console.log(((-5n)*(-7n)).toString())", "35"},
    {"mul_zero", "console.log((0n*#{@a}).toString())", "0"},
    # div / rem (quotient truncates toward 0; remainder takes dividend sign)
    {"div_small", "console.log((100n/7n).toString())", "14"},
    {"rem_small", "console.log((100n%7n).toString())", "2"},
    {"div_exact", "console.log((1000000000000000000000000n/1000000000000n).toString())", "1000000000000"},
    {"div_self", "console.log((#{@a}/#{@a}).toString())", "1"},
    {"div_lt", "console.log((7n/100n).toString())", "0"},
    {"rem_lt", "console.log((7n%100n).toString())", "7"},
    {"div_neg", "console.log(((-100n)/7n).toString())", "-14"},
    {"rem_neg", "console.log(((-100n)%7n).toString())", "-2"},
    {"div_neg_divisor", "console.log((100n/(-7n)).toString())", "-14"},
    # algebraic invariants (self-checking; result is a boolean)
    {"inv_divmod", "console.log((((#{@a}/987654321n)*987654321n + #{@a}%987654321n)===#{@a}))", "true"},
    {"inv_mul_div", "console.log(((#{@a}*987654321n)/987654321n===#{@a}))", "true"},
    {"inv_neg_mul", "console.log(((0n-#{@a})*987654321n===(0n-(#{@a}*987654321n))))", "true"}
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
            TinyLasers.Wasm.call_io(mod, "m", [], fuel: 200_000_000, transpile: true)
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
    test "bigint arith: #{name} (ASM ≡ node)" do
      assert {:ok, unquote(want)} == run_asm(unquote(src)),
             "#{unquote(name)}: ASM lane != node golden #{inspect(unquote(want))}"
    end
  end
end

defmodule Nexus.PorfforSimdStrcmpTest do
  @moduledoc """
  **SIMD v128 string-equality fast-path regression gate (ASM lane).**

  Porffor emits the ONLY SIMD it ever uses in the string-comparison fast path
  (`compiler/builtins/string.ts` `__Porffor_strcmp`): for strings of ≥16 bytes it loads two 16-byte
  chunks with `v128.load`, `v128.xor`s them, `v128.or`-reduces a second chunk in, and tests the result
  with `v128.any_true` to detect a differing byte in one vector step. The Washy interpreter previously
  implemented only `v128.load`/`store`/`const` and **raised** `unimplemented SIMD op 0xFD 81` (= `v128.xor`)
  on any longer-string `===`, so every comparison of two ≥16-byte strings trapped.

  This locks the three added `step/3` clauses (`v128.or`=80, `v128.xor`=81, `v128.any_true`=83) by driving
  real string equality through the Porffor→Washy ASM (transpile) lane across the chunk boundaries that
  exercise the SIMD path — equal, last-byte-diff, mid-string-diff, first-chunk-diff — at 16/32/33/48-byte
  lengths, asserting byte-equality with `node`. (test262 `language/statements/for/S12.6.3_A10*` failed on
  exactly this; the v128 ops are also emitted for any ≥16-byte string `===` across the suite.)
  """
  use ExUnit.Case, async: false

  @moduletag :porffor

  # 32 'a's, then variants that differ at controlled offsets so the xor/or/any_true reduction must catch them.
  @base String.duplicate("a", 32)

  # {name, source, expected-stdout (what `node` prints, trimmed)}
  @corpus [
    {"eq_32", "var a='#{@base}'; var b='#{@base}'; console.log(a===b)", "true"},
    {"eq_48", "var a='#{String.duplicate("x", 48)}'; var b='#{String.duplicate("x", 48)}'; console.log(a===b)", "true"},
    # differs in the LAST byte (second 16-byte chunk) → any_true must fire
    {"diff_last", "var a='#{@base}'; var b='#{String.duplicate("a", 31)}b'; console.log(a===b)", "false"},
    # differs in the FIRST byte (first chunk) → xor of chunk 0 already non-zero
    {"diff_first", "var a='#{@base}'; var b='b#{String.duplicate("a", 31)}'; console.log(a===b)", "false"},
    # differs mid-string (byte 20, second chunk) → or-reduction must carry chunk-1's xor
    {"diff_mid", "var a='#{@base}'; var b='#{String.duplicate("a", 20)}Z#{String.duplicate("a", 11)}'; console.log(a===b)", "false"},
    # 33 bytes — one full 16-chunk pair + a tail past the vector path, equal
    {"eq_33", "var a='#{String.duplicate("q", 33)}'; var b='#{String.duplicate("q", 33)}'; console.log(a===b)", "true"},
    # 33 bytes differing only in the non-vector tail byte
    {"diff_tail_33", "var a='#{String.duplicate("q", 33)}'; var b='#{String.duplicate("q", 32)}r'; console.log(a===b)", "false"},
    # control: short (<16 byte) strings never hit the SIMD path, must still be correct
    {"short_eq", "console.log('hi'==='hi')", "true"},
    {"short_ne", "console.log('hi'==='ho')", "false"}
  ]

  setup_all do
    if File.regular?(Nexus.Compilers.Js.Porffor.porf_entry()),
      do: :ok,
      else: {:skip, "porffor absent"}
  end

  defp run_asm(src) do
    with {:ok, wasm} <- Nexus.Compilers.Js.Porffor.compile(src),
         {:ok, mod} <- Nexus.Washy.decode(wasm) do
      task =
        Task.async(fn ->
          Process.put(:porffor_out, [])
          emit = fn s -> Process.put(:porffor_out, [s | Process.get(:porffor_out, [])]) end

          Process.put(:washy_imports, %{
            "a" => fn [v] -> emit.(to_string(v)); nil end,
            "b" => fn [v] -> emit.(<<trunc(v)::utf8>>); nil end,
            "c" => fn [] -> 0.0 end,
            "d" => fn [] -> 0.0 end
          })

          try do
            Nexus.Washy.call_io(mod, "m", [], fuel: 50_000_000, transpile: true)
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
    @tag :simd
    test "simd-strcmp: #{name} (ASM ≡ node)" do
      assert {:ok, unquote(want)} == run_asm(unquote(src)),
             "#{unquote(name)}: ASM lane != node golden #{inspect(unquote(want))}"
    end
  end
end

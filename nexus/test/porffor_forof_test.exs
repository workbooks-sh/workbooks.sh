defmodule Nexus.PorfforForOfTest do
  @moduledoc """
  **for-of control-flow + iterator-protocol regression gate (ASM lane).**

  Locks two root-cause codegen fixes in `compiler/codegen.js`:

  1. **`break`/`continue` branch offsets in a for-of were swapped.** The for-of lowers to
     `loop { block { … body … br 1(continue) } }` with no outer block — so `break` must target the inner
     `block` (br exits it → falls through `end loop`) and `continue` must target the `loop` (restart).
     `generateBreak` used `forof: 1` (→ the loop = a continue) and `generateContinue` used `forof: 2`
     (→ the block = a break): a `break` ran the loop to exhaustion and a `continue` exited it. Fixed to
     `break: 2`, `continue: 1`. (The automatic end-of-body `br 1` was already correct, so plain iteration
     never exposed it — only explicit break/continue did.)

  2. **for-of now drives the iterator protocol** for an `object`-typed iterable exposing `.next()` (a
     hand-rolled iterator, or a lazy generator lowered to an iterator object): per iteration
     `r = iter.next(); if (r.done) break; else value = r.value`, with `this` threaded to the iterator so a
     stateful `next()` advances. Previously such an object threw "non-iterable" at the for-of gate. A plain
     object with no `.next` still throws TypeError (at the point `.next()` resolves to undefined).

  Each case runs on the Porffor→Washy ASM (transpiler) lane and asserts byte-equality with `node`.
  """
  use ExUnit.Case, async: false

  @moduletag :porffor

  @iter "var it={__i:0,next:function(){var i=this.__i;this.__i=i+1;return {value:i,done:i>=4};},[Symbol.iterator]:function(){return this;}};"

  # {name, source, expected-stdout (what `node` prints, trimmed)}
  @corpus [
    {"array_break", "var o=[]; for (var x of [0,1,2,3]) { o.push(x); if (x>=1) break; } console.log(o.join(','))", "0,1"},
    {"array_continue", "var o=[]; for (var x of [0,1,2,3]) { if (x==1) continue; o.push(x); } console.log(o.join(','))", "0,2,3"},
    {"array_full", "var o=[]; for (var x of [5,6,7]) o.push(x); console.log(o.join(','))", "5,6,7"},
    {"nested_break_inner_only", "var o=[]; for (var i of [0,1]) { for (var j of [10,20,30]) { if(j==20) break; o.push(i+':'+j); } } console.log(o.join(','))", "0:10,1:10"},
    {"nested_continue_inner_only", "var o=[]; for (var i of [0,1]) { for (var j of [10,20,30]) { if(j==20) continue; o.push(i+':'+j); } } console.log(o.join(','))", "0:10,0:30,1:10,1:30"},
    # iterator protocol: a custom object with next()/Symbol.iterator is driven lazily
    {"iter_full", @iter <> "var o=[]; for (var x of it) o.push(x); console.log(o.join(','))", "0,1,2,3"},
    {"iter_break", @iter <> "var o=[]; for (var x of it) { o.push(x); if (x>=1) break; } console.log(o.join(','))", "0,1"},
    {"iter_continue", @iter <> "var o=[]; for (var x of it) { if (x==1) continue; o.push(x); } console.log(o.join(','))", "0,2,3"},
    # a plain (non-iterator) object is still not iterable
    {"plain_object_throws", "try { for (var x of {a:1}) {} console.log('NO'); } catch(e){ console.log('THREW'); }", "THREW"}
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
    @tag :forof
    test "for-of: #{name} (ASM ≡ node)" do
      assert {:ok, unquote(want)} == run_asm(unquote(src)),
             "#{unquote(name)}: ASM lane != node golden #{inspect(unquote(want))}"
    end
  end
end

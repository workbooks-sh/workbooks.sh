defmodule Nexus.PorfforFunctionDispatchTest do
  @moduledoc """
  **Function dispatch / argument-materialization regression gate (ASM lane).**

  Locks a root-cause codegen fix: an INDIRECT call whose args come from a spread (`f(...arr)`, and therefore
  every `fn.apply(thisArg, argsArray)` — which lowers to `Porffor.call(fn, ...argsArray)`) was materializing
  the callee's **rest parameter with a garbage count**. The spread was expanded to a FIXED 8 positional
  slots, so the indirect wrapper received `argc = leading + 8` regardless of the real array length, and a
  callee `function f(a, ...rest)` saw `rest.length` = `8 - 1` = 7 with empty padding (e.g.
  `f.apply(null, [1,2,3])` gave `"1:7:2,3,,,,"` instead of `"1:2:2,3"`).

  Fix (compiler/codegen.js): for a spread call, compute `argc` at runtime as `leading + spread.length`
  (hoisting the spread setup so `#spread` is initialized before the argc operand), and clamp the wrapper's
  rest length to `max(0, argc - namedParams)` so an under-supplied call (`f.apply(x, [])`, argc 0) yields
  `rest.length` 0 rather than a negative→huge value that loops forever.

  Each case runs on the Porffor→Washy ASM (transpiler) lane and asserts byte-equality with what `node`
  prints. `.call` (codegen-special-cased) is included as the control that was always correct.

  Also locks `Function.prototype.bind` on a GLOBAL-rooted native receiver (`Array.prototype.join.bind(x)`,
  a top-level `f.bind(thisArg)`): closure_convert now lowers it to a bound box `{__clo,__bound,bthis,fn}`
  (the `!rootedAtGlobal` guard previously skipped it → the no-op stub dropped `thisArg`). The bound box only
  works once the rest fix above lands, so they're locked together. (The member-rewrite pass needs a closure
  present in the file to fire, hence the `_c()` helper in those cases — real code always has one.)

  KNOWN-OPEN (tracked, NOT here): the uncurry-this idiom `Function.prototype.call.bind(method)` (test262
  propertyHelper.js) still fails one layer deeper — a builtin's receiver doesn't thread through the
  triple-indirection (`Function.prototype.call.apply(method,[o,k])` returns the wrong `this`); direct
  `f(...arr)` on a *statically-known* rest function is a separate pre-existing bug. See bd.
  """
  use ExUnit.Case, async: false

  @moduletag :porffor

  @f "function f(a,...rest){ return a + ':' + rest.length + ':' + rest.join(','); } "
  @g "function g(a,b){ return a + '-' + b; } "
  # a capturing closure so closure_convert's member-rewrite pass fires (it early-returns with no closures)
  @c "function _c(){ var z=1; return function(){ return z; }; } _c(); "

  # {name, source, expected-stdout (what `node` prints, trimmed)}
  @corpus [
    {"apply_rest", @f <> "console.log(f.apply(null,[1,2,3]))", "1:2:2,3"},
    {"call_rest", @f <> "console.log(f.call(null,1,2,3))", "1:2:2,3"},
    {"apply_rest_5args", @f <> "console.log(f.apply(null,[1,2,3,4,5]))", "1:4:2,3,4,5"},
    {"apply_rest_empty", @f <> "console.log(f.apply(null,[]))", "undefined:0:"},
    {"apply_no_rest", @g <> "console.log(g.apply(null,[7,8]))", "7-8"},
    {"call_no_rest", @g <> "console.log(g.call(null,7,8))", "7-8"},
    {"direct_rest", @f <> "console.log(f(1,2,3))", "1:2:2,3"},
    # global-rooted bind -> bound box (needs a closure present for the rewrite to fire)
    {"global_method_bind", @c <> "var b=Array.prototype.join.bind([1,2,3]); console.log(b())", "1,2,3"},
    {"global_fn_bind_this", @c <> "function f(a){return 'sum:'+(this.x+a);} var b=f.bind({x:10}); console.log(b(5))", "sum:15"},
    # uncurry-this: Function.prototype.call.bind(method) -> __uncurry box -> method.call(recv, ...args).
    # `usesUncurry` forces the member-rewrite even with NO source closures (propertyHelper.js shape).
    {"uncurry_hasown", "var __h = Function.prototype.call.bind(Object.prototype.hasOwnProperty); console.log(__h({a:1},'a') + ',' + __h({a:1},'b'))", "true,false"},
    {"uncurry_in_fn", "var __h = Function.prototype.call.bind(Object.prototype.hasOwnProperty); function chk(o,k){ return __h(o,k); } console.log(chk({x:1},'x'))", "true"},
    {"uncurry_join", "var __j = Function.prototype.call.bind(Array.prototype.join); console.log(__j([1,2,3],'-'))", "1-2-3"},
    # function-property read through an ANY-typed binding must hit the SAME store as the typed read.
    # A property set on a statically-known function (`f.foo = …`) and read back via an any-typed alias
    # (`var m; m = f; m.foo`) used to miss: the typed path resolved through a separate store while the
    # generic path read object_underlying. Locks the single-store fix (objectHackers no longer flattens
    # `assert`/`compareArray` member access to globals — see codegen.js objectHackers note).
    {"func_prop_via_anyvar", @c <> "function f(){} f.foo = function(){ return 'ok'; }; var m; m = f; console.log(m.foo())", "ok"},
    # the propertyHelper.js shape: an `assert`-named function carrying a method, called through a temp
    # (as closure_convert's box-dispatch rewrites every member call). Must resolve, not throw.
    {"assert_prop_via_temp", @c <> "function assert(){} assert.sv = function(a,b){ return a + ':' + b; }; var t; t = assert; console.log(t.sv(2,3))", "2:3"}
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
    @tag :function_dispatch
    test "function dispatch: #{name} (ASM ≡ node)" do
      assert {:ok, unquote(want)} == run_asm(unquote(src)),
             "#{unquote(name)}: ASM lane != node golden #{inspect(unquote(want))}"
    end
  end
end

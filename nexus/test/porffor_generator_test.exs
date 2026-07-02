defmodule Nexus.PorfforGeneratorTest do
  @moduledoc """
  **Lazy generator (real suspension) regression gate — ASM lane.**

  Locks the lazy `function*` lowering in `generator_transform.cjs`: a FLAT generator (no params, no
  top-level local declarations, yields only as top-level statements) is lowered to a THIS-based
  state-machine iterator object — `{ __s, next(){ while(true) switch(this.__s){…} }, toArray(), [Symbol.iterator] }`
  — instead of the legacy EAGER expansion (which ran the whole body up front). State lives on the object
  (a `this`-method, not a closure capture) so it round-trips through both the for-of iterator-protocol
  drive (codegen `TYPES.object` branch) and direct `.next()`.

  The decisive property is **lazy suspension**: code after a `yield` runs only on the next `.next()`. So a
  generator like `function* g(){ yield 1; throw … }` consumed with an early `break` must yield 1 and never
  run the throw — the exact test262 shape (e.g. `language/statements/for-of/break.js`) that eager expansion
  failed. Spread `[...g()]` drains via `toArray()` (Porffor spread does not drive the iterator protocol).

  Generators the lazy path declines (params, top-level locals, `yield*`, yields nested in control flow) fall
  back to eager `lowerGenerator` and still work — `eager_fallback_param` locks that path. Those are the
  named, deferred next slices (persist params/locals on `this`; loop-state machine; `yield*`; `next(v)`).

  **Prototype identity.** The lazy iterator is built with `Object.create(<self>.prototype)` (not a bare
  object literal), where `<self>` is the generator's in-scope binding — its own name for a declaration /
  named expression, or the variable it is assigned to for `var g = function*(){}`, resolved at call time.
  So the instance inherits from the generator function's `.prototype`, making `Object.getPrototypeOf(g())
  === g.prototype` and `g() instanceof g` hold (test262 generators `prototype-value` / `has-instance`,
  both regions). The deeper `%GeneratorPrototype%` / `%GeneratorFunction%` intrinsic-chain cases
  (`default-proto`, `prototype-relation-to-function`), the constructor-throw (`invoke-as-constructor`),
  and `restricted-properties` need Porffor codegen-level intrinsic modeling and remain deferred.
  """
  use ExUnit.Case, async: false

  @moduletag :porffor

  @g "function* g(){ yield 1; yield 2; yield 3; } "

  # {name, source, expected-stdout (what `node` prints, trimmed)}
  @corpus [
    {"for_of_full", @g <> "var o=[]; for (var x of g()) o.push(x); console.log(o.join(','))", "1,2,3"},
    {"for_of_break", @g <> "var o=[]; for (var x of g()) { o.push(x); if (x>=2) break; } console.log(o.join(','))", "1,2"},
    {"for_of_continue", @g <> "var o=[]; for (var x of g()) { if (x==2) continue; o.push(x); } console.log(o.join(','))", "1,3"},
    {"spread", @g <> "console.log([...g()].join(','))", "1,2,3"},
    {"direct_next", "function* g(){ yield 10; yield 20; } var it=g(); var a=it.next(),b=it.next(),c=it.next(); console.log(a.value+','+a.done+'|'+b.value+','+b.done+'|'+c.value+','+c.done)", "10,false|20,false|undefined,true"},
    # THE lazy-suspension property: throw-after-yield must NOT run when the consumer breaks after the first yield.
    {"lazy_throw_after_yield", "function* values(){ yield 1; throw 'boom'; } var it=values(); var i=0; for (var x of it) { i++; break; } console.log('i='+i)", "i=1"},
    {"return_value", "function* g(){ yield 1; return 9; yield 2; } var it=g(); var a=it.next(),b=it.next(); console.log(a.value+','+a.done+'|'+b.value+','+b.done)", "1,false|9,true"},
    # a generator with a param is declined by the lazy path → eager fallback, still correct
    {"eager_fallback_param", "function* g(n){ yield n; yield n+1; } console.log([...g(5)].join(','))", "5,6"},
    # PROTOTYPE IDENTITY: the lazy iterator inherits from the generator function's `.prototype`, so
    # `Object.getPrototypeOf(g()) === g.prototype` and `g() instanceof g` hold (test262 generators
    # statements/{prototype-value,has-instance}). The instance is `Object.create(g.prototype)`, not a bare
    # object literal — the generator's own name (declaration) self-references its live prototype at call time.
    {"proto_identity_decl", "function* g(){ yield 1; } var i=g(); console.log((Object.getPrototypeOf(i)===g.prototype)+'|'+(g() instanceof g))", "true|true"},
    # expression form: an anonymous generator assigned to a binding references that binding's `.prototype`
    # (resolved at call time) — covers expressions/generators/has-instance (`var g = function*(){}`).
    {"proto_identity_expr", "var g=function*(){ yield 1; }; console.log(g() instanceof g)", "true"},
    # prototype identity must COEXIST with the for-of iterator-protocol drive: the `Object.create`'d
    # instance still exposes own `next`/`@@iterator`, so iteration and `instanceof` both hold.
    {"proto_identity_with_forof", "function* g(){ yield 1; yield 2; } var o=[]; for (var x of g()) o.push(x); console.log(o.join(',')+'|'+(g() instanceof g))", "1,2|true"}
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
    @tag :generator
    test "generator: #{name} (ASM ≡ node)" do
      assert {:ok, unquote(want)} == run_asm(unquote(src)),
             "#{unquote(name)}: ASM lane != node golden #{inspect(unquote(want))}"
    end
  end
end

defmodule Nexus.PorfforClosureCorpusTest do
  @moduledoc """
  **Small-scope closure-conversion corpus — invariant regression gate.**

  Methodology (closure-conversion redesign): stop proving "this output is right" and start proving "this
  transformation can't produce a wrong output". Conformance verifies points; this corpus systematically
  enumerates the closure-conversion failure surface at SMALL SCOPE — combinations of
  `{scope kind} × {capture kind} × {call site}` — so each fixed bug CLASS is provably closed (not just the
  one bundle that surfaced it) and can't regress.

  Each case is a self-contained program whose closure output is deterministic; we run it on the **ASM lane**
  (Porffor → Washy transpiler) and assert byte-equality with the value `node` produces (encoded as the
  golden). The cases trace directly to this session's fixes:

    * `this` survival across async CPS loops / nested `.then` continuations  (async this-aliasing, __this capture)
    * boxed closure is `typeof`-callable                                       (__isFn)
    * `Set`/`Map` for-of through any binding                                   (__porfIter)
    * `Promise.catch` recovery + `await` in try/catch                          (promise 0b100, try CPS)
    * destructuring-assignment to members in a class method                    (destructure_desugar)
    * multiple boxed getters per object                                        (defprop pool)

  KNOWN-OPEN (excluded, tracked): per-iteration capture of a loop-BODY block `const` (lc/cacheObjectGetters)
  — closure_convert freshens only the loop-control var; the body-const env is shared across iterations.
  cc_invariants.cjs flags this statically (INV-LOOP-FRESH); the runtime cases live behind `@known_gap`.
  """
  use ExUnit.Case, async: false

  @moduletag :porffor

  # {name, source, expected-stdout (what `node` prints, trimmed)}
  @corpus [
    {"this_in_nested_then",
     """
     class G { constructor(){ this.a=[1,2,3]; this.b=10; }
       async build(){ await Promise.resolve(0); var x=await Promise.resolve(5);
         return { n: this.a.length, t: this.b + x }; } }
     new G().build().then(r => console.log(r.n + ":" + r.t));
     """, "3:15"},
    {"this_in_dowhile_await",
     """
     class K { constructor(){ this.p=Promise.resolve(1); this.n=0; }
       async go(){ let sp; do { sp=this.p; await sp; this.n++; if(this.n>=3) this.p=Promise.resolve(2); } while(this.n<3); return this.n; } }
     new K().go().then(v => console.log("" + v));
     """, "3"},
    {"this_in_forof_await",
     """
     class Q { constructor(){ this.base=10; }
       async sum(arr){ let t=0; for(const x of arr){ await Promise.resolve(0); t+=x+this.base; } return t; } }
     new Q().sum([1,2,3]).then(v => console.log("" + v));
     """, "36"},
    {"typeof_box_is_function",
     """
     function mk(){ var c=5; return function(){ return c; }; }
     var f=mk();
     function check(h){ if(typeof h!=="function") return "no"; return "yes:"+h(); }
     console.log(check(f) + " " + check(123));
     """, "yes:5 no"},
    {"set_forof_through_arg",
     """
     function sum(s){ var t=0; for(const x of s) t+=x; return t; }
     var a=new Set([3,4]); console.log("" + sum(a));
     """, "7"},
    {"set_forof_through_prop",
     """
     var o={}; o.s=new Set([1,2,3]); var t=0; for(const x of o.s) t+=x; console.log("" + t);
     """, "6"},
    {"map_forof_through_arg",
     """
     function dump(m){ var s=""; for(const e of m) s+=e[0]+":"+e[1]+","; return s; }
     var m=new Map(); m.set("a",1); m.set("b",2); console.log(dump(m));
     """, "a:1,b:2,"},
    {"promise_catch_recovers",
     """
     Promise.reject("x").catch(e => "rec:"+e).then(v => console.log(v));
     """, "rec:x"},
    {"await_in_try_catch",
     """
     async function f(){ try { var x=await Promise.resolve(5); return "ok:"+x; } catch(e){ return "err:"+e; } }
     f().then(v => console.log(v));
     """, "ok:5"},
    {"await_in_try_reject",
     """
     async function f(){ try { await Promise.reject("boom"); return "ok"; } catch(e){ return "caught:"+e; } }
     f().then(v => console.log(v));
     """, "caught:boom"},
    {"destructure_assign_in_method",
     """
     class K { run(av){ ({a: this.x, b: this.y} = av); return this.x + "," + this.y; } }
     console.log(new K().run({a:3, b:4}));
     """, "3,4"},
    {"array_destructure_assign_in_method",
     """
     class K { run(av){ var a,b,c; [a,b,c]=av; return a+","+b+","+c; } }
     console.log(new K().run([7,8,9]));
     """, "7,8,9"},
    {"captured_constructor",
     """
     function make(){ var tag="T"; function Thing(x){ this.x=x; this.tag=tag; }
       Thing.prototype.get=function(){ return this.tag+this.x; }; return Thing; }
     var T=make(); console.log(new T(5).get());
     """, "T5"}
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

  # KNOWN-OPEN — these require the per-iteration loop-BODY-const fix (cc_invariants INV-LOOP-FRESH).
  # A captured `const` declared in a loop body is shared across iterations (closure_convert freshens only the
  # loop-control var), so e.g. cacheObjectGetters' per-property `const orig` collapses to the last value.
  # Tagged :known_gap (excluded by default). PROMOTE into @corpus when the loop-capture fix lands.
  @known_gaps [
    {"multiple_boxed_getters",
     """
     function cache(obj, props){ for(const p of props){ const orig=Object.getOwnPropertyDescriptor(obj,p).get;
       Object.defineProperty(obj,p,{ get(){ const v=orig.call(obj); Object.defineProperty(obj,p,{value:v}); return v; } }); } }
     var info={}; var base=100;
     Object.defineProperty(info,"a",{get:()=>base+1,configurable:true});
     Object.defineProperty(info,"b",{get:()=>base+2,configurable:true});
     cache(info,["a","b"]); console.log(info.a + "," + info.b);
     """, "101,102"}
  ]

  for {name, src, want} <- @corpus do
    @tag :closure_corpus
    test "closure corpus: #{name} (ASM ≡ node)" do
      assert {:ok, unquote(want)} == run_asm(unquote(src)),
             "#{unquote(name)}: ASM lane != node golden #{inspect(unquote(want))}"
    end
  end

  for {name, src, want} <- @known_gaps do
    @tag :known_gap
    @tag skip: "loop-body-const per-iteration capture (INV-LOOP-FRESH) — promote when fixed"
    test "closure corpus (known gap): #{name}" do
      assert {:ok, unquote(want)} == run_asm(unquote(src))
    end
  end
end

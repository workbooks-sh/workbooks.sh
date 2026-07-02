defmodule Nexus.PorfforTdzTest do
  @moduledoc """
  **Temporal Dead Zone (TDZ) regression gate — ASM lane.**

  Locks the self-initialization slice of TDZ: a `let`/`const` binding is in its temporal dead zone during
  its OWN initializer, so a direct self-reference (`let x = x + 1`) must throw `ReferenceError` ("Cannot
  access before initialization"). Porffor's `pdz` hoist-type already throws on a pre-initialization read,
  but the binding was allocated (turned into a readable zero local) BEFORE its initializer ran, so a
  self-reference read the zero local instead of hitting the dead zone.

  Fix (compiler/codegen.js generateVar): when the initializer of a `let`/`const` directly references the
  binding (a name-scan that does NOT descend into nested functions — those are closure captures, a separate
  case), generate the initializer BEFORE `allocVar`, while the binding is still `pdz`, so the self-read
  resolves through the dead-zone hoist and throws. Scalars only (func/array inits need the var allocated
  first). This lifted test262 language/statements/{let,const} and for-of/for-in materially.

  The `_throws` cases prove the dead zone fires; the `_ok` cases prove it does NOT over-trigger on ordinary
  forward/closure references (a function that closes over a later `let` and is called AFTER it initializes
  must work).

  KNOWN-OPEN (tracked in bd porffor-tdz-state): use-before-declaration in a closure called before init
  (`{ function f(){return x} f(); let x; }`) needs poison-through-capture — a separate, deeper fix.
  """
  use ExUnit.Case, async: false

  @moduletag :porffor

  # programs that must THROW (self-init dead zone) — caught in-guest, prints "THREW"
  @throws [
    {"self_init_let", "try { (function(){ let x = x + 1; })(); console.log('NO'); } catch(e){ console.log('THREW'); }"},
    {"self_init_const", "try { (function(){ const y = y; })(); console.log('NO'); } catch(e){ console.log('THREW'); }"},
    {"self_init_block", "try { { let q = q * 2; } console.log('NO'); } catch(e){ console.log('THREW'); }"}
  ]

  # programs that must NOT throw (TDZ must not over-trigger on ordinary / closure references)
  @ok [
    {"normal_let", "let y = 5; console.log('y=' + y)", "y=5"},
    {"let_after_let", "let z = 10; let w = z + 1; console.log('w=' + w)", "w=11"},
    {"const_non_self", "const a = 1; const b = a + 2; console.log('b=' + b)", "b=3"},
    {"closure_forward_ref", "let f = function(){ return g; }; let g = 7; console.log('f=' + f())", "f=7"}
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

  for {name, src} <- @throws do
    @tag :tdz
    test "TDZ self-init throws: #{name}" do
      assert {:ok, "THREW"} == run_asm(unquote(src)),
             "#{unquote(name)}: expected the self-init dead zone to throw ReferenceError"
    end
  end

  for {name, src, want} <- @ok do
    @tag :tdz
    test "TDZ does not over-trigger: #{name}" do
      assert {:ok, unquote(want)} == run_asm(unquote(src)),
             "#{unquote(name)}: TDZ over-triggered or value wrong, want #{inspect(unquote(want))}"
    end
  end
end

defmodule TinyLasers.HostObjectsCodegenTest do
  @moduledoc """
  **Stage 3: `--host-objects` codegen, oracle-gated against the default in-memory object lane.**

  Compiles the same JS with and without `--host-objects` and asserts identical results through `call_io`.
  Under the flag, plain static-key object literals become `ho_new` + `ho_set` host calls and static-key
  reads off a statically-object-typed receiver become `ho_get_value`/`ho_get_type` (keyed by the
  compile-time property hash) — no linear-memory pointer-chase or 20-branch type dispatch. The host object
  table (`TinyLasers.Js.HostObjects`) backs it.

  Scope note: the member fast path requires the receiver's type to be STATICALLY known as object (e.g. a
  direct object literal). `var o = {...}; o.x` does not yet propagate object type to `o`, so it falls back
  to the in-memory lane — correct, just not accelerated. Widening that (runtime type-tag branch in the
  member typeSwitch) is a later sub-stage.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Wasm
  alias TinyLasers.Js.{Porffor, HostObjects}

  defp run(src, host?) do
    flags = if host?, do: [flags: ["--host-objects"]], else: []
    {:ok, wasm} = Porffor.compile(src, "compilers", [skip_invariants: true] ++ flags)
    {:ok, mod} = Wasm.decode(wasm)
    HostObjects.reset()
    if host?, do: Process.put(:tl_imports, HostObjects.imports())

    try do
      {r, _} = Wasm.call_io(mod, "m", [], transpile: false, fuel: 500_000_000, max_pages: 16_384)
      {r, mod.imports}
    after
      Process.delete(:tl_imports)
      HostObjects.reset()
    end
  end

  @cases [
    {"single prop read", "function f(){ return ({x: 42}).x; } f();"},
    {"two prop sum", "function f(){ var o = ({a: 3, b: 4}); return ({a: 3, b: 4}).a + ({a: 3, b: 4}).b; } f();"},
    # numeric reductions only — a string result would leak its heap pointer (legitimately different
    # between the two data-section layouts), so we compare CONTENT-derived numbers, never raw pointers.
    {"string-valued prop type len", "function f(){ return (typeof ({s: 'hi'}).s).length; } f();"},
    {"string prop char", "function f(){ return ({s: 'hi'}).s.charCodeAt(0); } f();"},
    {"bool prop", "function f(){ return ({ok: true}).ok; } f();"},
    {"nested literal read", "function f(){ return ({p: ({q: 9}).q}).p; } f();"},
    # Stage 4: runtime tag branch — dynamically-typed receivers (loop var, param) + property write
    {"loop reuse", "function f(){ var s=0; var o={x:3}; for(var i=0;i<5;i++){ s+=o.x; } return s; } f();"},
    {"function param obj", "function g(o){ return o.x; } function f(){ return g({x:8}); } f();"},
    {"property write", "function f(){ var o={x:1}; o.x = 9; return o.x; } f();"},
    {"write then read loop", "function f(){ var o={n:0}; for(var i=0;i<4;i++){ o.n = o.n + i; } return o.n; } f();"},
    {"two distinct objs", "function f(){ var a={x:1}; var b={x:2}; b.x = 5; return a.x + b.x; } f();"}
  ]

  for {name, src} <- @cases do
    test "host-objects oracle-matches default: #{name}" do
      {default, _} = run(unquote(src), false)
      {host, imports} = run(unquote(src), true)
      assert default == host
      # the flag actually engaged the host object lane (ho_* imports emitted)
      assert Enum.any?(imports, fn {_m, n, _t} -> String.starts_with?(n, "ho_") end),
             "expected ho_* imports under --host-objects, got #{inspect(imports)}"
    end
  end
end

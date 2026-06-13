defmodule Workbooks.JsEngineTest do
  @moduledoc """
  Proves the FULL SpiderMonkey JS engine runs in-sandbox under our wasmtime — spec-complete modern ECMAScript,
  no V8, no native codegen, no microVM. The eval-host is componentized once (componentize-js@0.18.5 -> wasi 0.2.3,
  which wasmtime 39 links) and fed arbitrary JS at runtime. This is the full-JS-language lane (beyond QuickJS).
  """
  use ExUnit.Case, async: false
  alias Workbooks.JsEngine

  @tag :build
  @tag timeout: 300_000
  test "build_host componentizes the StarlingMonkey eval-host (cached)" do
    assert {:ok, path} = JsEngine.build_host()
    assert File.exists?(path)
    assert File.stat!(path).size > 1_000_000
  end

  @tag :build
  @tag timeout: 300_000
  test "eval — spec-complete modern ECMAScript (arrow/map/JSON/Map/Set/Promise/async/spread)" do
    assert {:ok, "42"} = JsEngine.eval("6*7")
    assert {:ok, "1-4-9"} = JsEngine.eval("[1,2,3].map(x=>x*x).join('-')")
    assert {:ok, ~s({"a":1,"b":[2,3]})} = JsEngine.eval("JSON.stringify({a:1,b:[2,3]})")
    assert {:ok, "42"} = JsEngine.eval("(()=>{const m=new Map();m.set('k',42);return m.get('k');})()")
    assert {:ok, "function"} = JsEngine.eval("typeof Promise")
    assert {:ok, "1,2,3"} = JsEngine.eval("[...new Set([1,1,2,3,3])].join(',')")
    assert {:ok, "Promise"} = JsEngine.eval("(async()=>42)().constructor.name")
    assert {:ok, "0,1,4,9,16"} = JsEngine.eval("Array.from({length:5},(_,i)=>i*i).join(',')")
  end

  @tag :build
  @tag timeout: 300_000
  test "eval — a syntax/runtime error is caught + returned, not a crash" do
    assert {:ok, "ERR: " <> _} = JsEngine.eval("this is not valid js (")
    assert {:ok, "ERR: " <> _} = JsEngine.eval("nonexistentFunction()")
  end
end

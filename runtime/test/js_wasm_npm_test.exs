defmodule Workbooks.JsWasmNpmTest do
  @moduledoc """
  Documents a DEFERRED capability + acts as a tripwire: `WebAssembly` is absent in the StarlingMonkey
  eval-host (jitless SpiderMonkey-compiled-to-wasm cannot host a nested wasm engine in-guest). So npm
  packages that `WebAssembly.instantiate` a bundled `.wasm` (sql.js, @swc/wasm) can't run via the JS
  pipeline.

  Escapes (recorded in js-ecosystem.json): (1) host-brokered sibling wasm instance — intercept
  WebAssembly.instantiate → run the inner .wasm on host wasmtime as a flat-forest sibling (the
  toolkit-isolation model); (2) use the underlying capability via our own Forge wasi lane instead
  (sql.js → the in-tree sqlite.wasm). If a future engine rebuild adds WebAssembly, this test flips.
  """
  use ExUnit.Case, async: false
  alias Workbooks.JsEngine

  setup_all do
    {:ok, sm?: match?({:ok, _}, JsEngine.build_host())}
  end

  @tag :build
  test "WebAssembly is absent in the eval-host (wasm-npm deferred tripwire)", %{sm?: sm?} do
    if not sm? do
      IO.puts("\n[skip] SM eval-host not built")
    else
      assert {:ok, "undefined"} = JsEngine.eval("typeof WebAssembly")
    end
  end
end

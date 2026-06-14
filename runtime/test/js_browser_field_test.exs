defmodule Workbooks.JsBrowserFieldTest do
  @moduledoc """
  Proves package.json `browser` field remapping — esbuild (platform=browser default) resolves a package's
  `browser` entry over `main`, so node-vs-browser dual packages pick the browser build. No network.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, JsEngine}

  @root Path.expand(Path.join(__DIR__, "../compilers"))

  setup_all do
    {:ok, ready?: match?({:ok, _}, JsEngine.build_host()) and File.regular?(Path.join(@root, "esbuild/esbuild.wasm"))}
  end

  @tag :build
  @tag timeout: 60_000
  test "browser field is preferred over main", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] engines/esbuild not built")
    else
      dir = Path.join(System.tmp_dir!(), "jsbf_test")
      File.rm_rf(dir)
      File.mkdir_p!(Path.join(dir, "src"))
      File.mkdir_p!(Path.join(dir, "node_modules/mypkg"))
      File.write!(Path.join(dir, "package.json"), ~s({"name":"t","version":"1.0.0","type":"module"}))
      File.write!(Path.join(dir, "node_modules/mypkg/package.json"), ~s({"name":"mypkg","version":"1.0.0","main":"node.js","browser":"browser.js"}))
      File.write!(Path.join(dir, "node_modules/mypkg/node.js"), ~s|module.exports = "NODE";|)
      File.write!(Path.join(dir, "node_modules/mypkg/browser.js"), ~s|module.exports = "BROWSER";|)
      File.write!(Path.join([dir, "src", "main.js"]), ~s|import v from "mypkg"; console.log("BF"+v)|)

      assert {:ok, js} = Compilers.esbuild_bundle_dir(dir, "src/main.js", [node_polyfills: true], @root)
      assert {:ok, out} = JsEngine.run_program(js)
      assert String.trim(out) == "BFBROWSER"
    end
  end
end

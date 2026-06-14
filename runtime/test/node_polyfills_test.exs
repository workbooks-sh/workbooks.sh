defmodule Workbooks.NodePolyfillsTest do
  @moduledoc """
  Proves Node built-in modules work on the StarlingMonkey (web-platform) path via the `node_polyfills`
  esbuild preset — the keystone for running node-authored npm libraries in-sandbox. StarlingMonkey has
  no Node builtins; the preset aliases each pure builtin to its JS polyfill (installed on demand) + injects
  a `process`/`global` banner. Full pipeline: esbuild_bundle_dir(node_polyfills: true) -> JsEngine.run_program.

  Covers the PURE tier (path/events/util/querystring + the process shim). Impure builtins (fs/net/crypto)
  stay brokered; Buffer-global and full stream event-loop are tracked separately in js-ecosystem.json.

  Skips unless the JS engines + esbuild are built and the npm registry is reachable (the preset installs
  polyfill packages) — same :build cadence as the other JS lane tests.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, JsEngine}

  @root Path.expand(Path.join(__DIR__, "../compilers"))
  @esbuild Path.join(@root, "esbuild/esbuild.wasm")
  @clang Path.expand(Path.join(__DIR__, "../compilers/clang/clang-root/llvm.core.wasm"))

  setup_all do
    ready = match?({:ok, _}, JsEngine.build_host()) and File.regular?(@esbuild) and File.regular?(@clang)
    {:ok, ready?: ready}
  end

  defp run(name, main, ready?) do
    dir = Path.join(System.tmp_dir!(), "nbp_test_#{name}")
    File.rm_rf(dir)
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "package.json"), ~s({"name":"t","version":"1.0.0","type":"module"}))
    File.write!(Path.join([dir, "src", "main.js"]), main)

    if ready? do
      case Compilers.esbuild_bundle_dir(dir, "src/main.js", [node_polyfills: true], @root) do
        {:ok, js} ->
          case JsEngine.run_program(js) do
            {:ok, out} -> String.trim(out)
            other -> flunk("run_program failed: #{inspect(other)}")
          end

        other ->
          flunk("bundle failed: #{inspect(other) |> String.slice(0, 200)}")
      end
    end
  end

  @tag :build
  @tag timeout: 300_000
  test "node builtins (path/events/util/querystring) + process shim run on StarlingMonkey", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] JS engines/esbuild not built or registry unreachable")
    else
      assert run("path", ~s/import path from "path"; console.log(path.join("a","b","..","c")+"|"+path.extname("f.txt"))/, ready?) =~ "a/c|.txt"
      assert run("events", ~s|import {EventEmitter} from "events"; const e=new EventEmitter();let r=0;e.on("x",v=>r=v);e.emit("x",7);console.log(r)|, ready?) == "7"
      assert run("util", ~s|import util from "util"; console.log(util.format("%s=%d","n",3))|, ready?) == "n=3"
      assert run("qs", ~s|import qs from "querystring"; console.log(qs.parse("a=1&b=2").b)|, ready?) == "2"
      assert run("process", ~s|console.log(process.platform+"/"+typeof process.nextTick)|, ready?) == "wasi/function"
    end
  end
end

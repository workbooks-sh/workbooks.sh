defmodule Workbooks.JsModulesTest do
  @moduledoc """
  Proves the module-system surfaces esbuild + run_program handle end-to-end: dynamic `import()`,
  CJS↔ESM default interop, JSON imports, circular dependencies, and top-level await. Multi-file projects
  bundled then run. Skips unless engines + esbuild built and registry reachable.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Npm, Compilers, JsEngine}

  @root Path.expand(Path.join(__DIR__, "../compilers"))

  setup_all do
    {:ok, ready?: match?({:ok, _}, JsEngine.build_host()) and File.regular?(Path.join(@root, "esbuild/esbuild.wasm"))}
  end

  defp run(name, files, dep \\ nil) do
    dir = Path.join(System.tmp_dir!(), "jsmod_#{name}")
    File.rm_rf(dir)
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "package.json"), ~s({"name":"t","version":"1.0.0","type":"module"}))
    Enum.each(files, fn {rel, body} -> File.write!(Path.join(dir, rel), body) end)
    if dep, do: {:ok, _} = Npm.install_tree([%{name: dep, req: "*", pin: nil}], dir)

    with {:ok, js} <- Compilers.esbuild_bundle_dir(dir, "src/main.js", [node_polyfills: true], @root),
         {:ok, out} <- JsEngine.run_program(js) do
      String.trim(out)
    end
  end

  @tag :build
  @tag timeout: 300_000
  test "dynamic import / interop / JSON / circular / top-level-await", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] engines/esbuild not built or registry unreachable")
    else
      assert run("dyn", %{"src/main.js" => ~s|(async()=>{const m=await import("lodash");console.log("DI"+m.default.chunk([1,2,3,4],2).length)})()|}, "lodash") == "DI2"
      assert run("interop", %{"src/main.js" => ~s|import _ from "lodash";console.log("IN"+_.add(1,2))|}, "lodash") == "IN3"
      assert run("json", %{"src/data.json" => ~s|{"x":5,"y":[1,2,3]}|, "src/main.js" => ~s|import d from "./data.json";console.log("J"+d.x+d.y.length)|}) == "J53"
      assert run("circ", %{
               "src/a.js" => ~s|import {b} from "./b.js"; export const a=()=>"a"+b(); export const av="A";|,
               "src/b.js" => ~s|import {av} from "./a.js"; export const b=()=>"b"+av;|,
               "src/main.js" => ~s|import {a} from "./a.js"; console.log("CIRC"+a())|
             }) == "CIRCabA"
      assert run("tla", %{"src/main.js" => ~s|const v = await Promise.resolve(7); console.log("TLA"+v)|}) == "TLA7"
    end
  end
end

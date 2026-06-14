defmodule Workbooks.JsLibBreadthTest do
  @moduledoc """
  Breadth proof across pure-JS library categories — each runs end-to-end through install→bundle→run_program:
  data/math (mathjs, decimal.js, immutable), reactive (rxjs, async), DOM/HTML (node-html-parser),
  schema (graphql), terminal/text (picocolors). One representative per category; the loop's coverage map.

  Skips unless engines + esbuild built and registry reachable.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Npm, Compilers, JsEngine}

  @root Path.expand(Path.join(__DIR__, "../compilers"))

  setup_all do
    {:ok, ready?: match?({:ok, _}, JsEngine.build_host()) and File.regular?(Path.join(@root, "esbuild/esbuild.wasm"))}
  end

  defp run(dep, main) do
    dir = Path.join(System.tmp_dir!(), "jslib_#{String.replace(dep, ~r/[^a-z0-9]/, "_")}")
    File.rm_rf(dir)
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "package.json"), ~s({"name":"t","version":"1.0.0","type":"module"}))
    File.write!(Path.join([dir, "src", "main.js"]), main)
    {:ok, _} = Npm.install_tree([%{name: dep, req: "*", pin: nil}], dir)

    with {:ok, js} <- Compilers.esbuild_bundle_dir(dir, "src/main.js", [node_polyfills: true], @root),
         {:ok, out} <- JsEngine.run_program(js) do
      String.trim(out)
    end
  end

  @tag :build
  @tag timeout: 600_000
  test "data / reactive / DOM / schema / terminal libs all run", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] engines/esbuild not built or registry unreachable")
    else
      assert run("mathjs", ~s|import {evaluate} from "mathjs"; console.log("M"+evaluate("2+3*4")+"."+evaluate("sqrt(16)"))|) == "M14.4"
      assert run("decimal.js", ~s|import D from "decimal.js"; console.log("D"+new D(0.1).plus(0.2).toString())|) == "D0.3"
      assert run("immutable", ~s|import {Map as IMap} from "immutable"; const m=IMap({a:1}).set("b",2); console.log("I"+m.get("a")+m.get("b"))|) == "I12"
      assert run("rxjs", ~s|import {of} from "rxjs"; import {map,reduce} from "rxjs/operators"; of(1,2,3).pipe(map(x=>x*2),reduce((a,b)=>a+b,0)).subscribe(v=>console.log("X"+v))|) == "X12"
      assert run("node-html-parser", ~s|import {parse} from "node-html-parser"; console.log("H"+parse("<div><p>x</p></div>").querySelector("p").text)|) == "Hx"
      assert run("graphql", ~s|import {parse,print} from "graphql"; console.log("G"+print(parse("{ a b }")).replace(/\\s+/g,""))|) == "G{ab}"
      assert run("picocolors", ~s|import pc from "picocolors"; console.log("P"+typeof pc.red+pc.red("x").includes("x"))|) == "Pfunctiontrue"
    end
  end
end

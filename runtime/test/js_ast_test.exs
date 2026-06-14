defmodule Workbooks.JsAstTest do
  @moduledoc """
  Proves the AST/compiler library category — code-processing libs (the backbone of build tools, linters,
  formatters) run in-sandbox through the real pipeline: acorn (JS parser), @babel/parser, postcss (async).

  Known ceiling: very large bundles (~10MB+, e.g. the full `typescript` lib) exceed the eval-host/QuickJS
  runtime limit — tracked in js-ecosystem.json. TS *transpilation* is covered by esbuild ts-strip instead.

  Skips unless engines + esbuild built and registry reachable.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Npm, Compilers, JsEngine}

  @root Path.expand(Path.join(__DIR__, "../compilers"))

  setup_all do
    {:ok, ready?: match?({:ok, _}, JsEngine.build_host()) and File.regular?(Path.join(@root, "esbuild/esbuild.wasm"))}
  end

  defp run(name, dep, req, main) do
    dir = Path.join(System.tmp_dir!(), "jsast_#{name}")
    File.rm_rf(dir)
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "package.json"), ~s({"name":"t","version":"1.0.0","type":"module"}))
    File.write!(Path.join([dir, "src", "main.js"]), main)
    {:ok, _} = Npm.install_tree([%{name: dep, req: req, pin: nil}], dir)

    with {:ok, js} <- Compilers.esbuild_bundle_dir(dir, "src/main.js", [node_polyfills: true], @root),
         {:ok, out} <- JsEngine.run_program(js) do
      String.trim(out)
    end
  end

  @tag :build
  @tag timeout: 300_000
  test "acorn / @babel/parser / postcss parse + transform in-sandbox", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] engines/esbuild not built or registry unreachable")
    else
      assert run("acorn", "acorn", "^8.11.0", ~s|import {parse} from "acorn"; const a=parse("1+2*3",{ecmaVersion:2020}); console.log("ac"+a.type+"."+a.body[0].type)|) == "acProgram.ExpressionStatement"
      assert run("babel", "@babel/parser", "^7.24.0", ~s|import {parse} from "@babel/parser"; const a=parse("const x=()=>1"); console.log("ba"+a.type+"."+a.program.body[0].type)|) == "baFile.VariableDeclaration"
      assert run("postcss", "postcss", "^8.4.0", ~s|import postcss from "postcss"; (async()=>{const r=await postcss([]).process("a{color:red}",{from:undefined}); console.log("pc"+r.css)})()|) == "pca{color:red}"
    end
  end
end

defmodule Workbooks.JsDecoratorsTest do
  @moduledoc """
  Proves TypeScript decorators in-sandbox: legacy `experimentalDecorators` (the dominant flavor —
  Angular/NestJS/TypeORM/class-validator) transform via esbuild + run, and `emitDecoratorMetadata` +
  reflect-metadata (Reflect.defineMetadata/getMetadata) works. TC39 stage-3 decorators are not transformed
  by the vendored esbuild (passthrough) — tracked as partial in js-ecosystem.json.

  Skips unless engines + esbuild built and registry reachable.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Npm, Compilers, JsEngine}

  @root Path.expand(Path.join(__DIR__, "../compilers"))

  setup_all do
    {:ok, ready?: match?({:ok, _}, JsEngine.build_host()) and File.regular?(Path.join(@root, "esbuild/esbuild.wasm"))}
  end

  defp run(name, tsconfig, main, dep \\ nil) do
    dir = Path.join(System.tmp_dir!(), "jsdec_#{name}")
    File.rm_rf(dir)
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "package.json"), ~s({"name":"t","version":"1.0.0"}))
    File.write!(Path.join(dir, "tsconfig.json"), tsconfig)
    File.write!(Path.join([dir, "src", "main.ts"]), main)
    if dep, do: {:ok, _} = Npm.install_tree([%{name: dep, req: "*", pin: nil}], dir)

    with {:ok, js} <- Compilers.esbuild_bundle_dir(dir, "src/main.ts", [node_polyfills: true], @root),
         {:ok, out} <- JsEngine.run_program(js) do
      String.trim(out)
    end
  end

  @tag :build
  @tag timeout: 300_000
  test "legacy decorators + emitDecoratorMetadata/reflect-metadata", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] engines/esbuild not built or registry unreachable")
    else
      legacy_tsconfig = ~s({"compilerOptions":{"experimentalDecorators":true,"target":"ES2020"}})

      assert run("legacy", legacy_tsconfig, ~s|function double(t,k,desc){const o=desc.value;desc.value=function(){return o.apply(this,arguments)*2};return desc;}\nclass C{ @double calc(){return 21} }\nconsole.log("LEG"+new C().calc())|) == "LEG42"

      meta_tsconfig = ~s({"compilerOptions":{"experimentalDecorators":true,"emitDecoratorMetadata":true,"target":"ES2020"}})

      assert run("metadata", meta_tsconfig, ~s|import "reflect-metadata";\nconst o={};\nReflect.defineMetadata("role","admin",o);\nconsole.log("RM"+Reflect.getMetadata("role",o))|, "reflect-metadata") == "RMadmin"
    end
  end
end

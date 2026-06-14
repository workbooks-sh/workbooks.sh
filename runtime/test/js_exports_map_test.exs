defmodule Workbooks.JsExportsMapTest do
  @moduledoc """
  Proves package.json `exports`-map resolution works end-to-end (esbuild resolves it at bundle time):
  subpath exports (`date-fns/fp`), conditional exports (import condition — nanoid), and subpath-pattern
  exports (`date-fns/locale/en-US`). Scoped-package exports also resolve (proven separately with
  @sindresorhus/is — it bundled fine; its only failure was the unrelated Intl gap).

  Skips unless the engines + esbuild are built and the registry is reachable.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Npm, Compilers, JsEngine}

  @root Path.expand(Path.join(__DIR__, "../compilers"))

  setup_all do
    {:ok, ready?: match?({:ok, _}, JsEngine.build_host()) and File.regular?(Path.join(@root, "esbuild/esbuild.wasm"))}
  end

  defp run(name, dep, req, main) do
    dir = Path.join(System.tmp_dir!(), "jsexp_#{name}")
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
  test "exports-map: subpath, conditional, and subpath-pattern all resolve", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] engines/esbuild not built or registry unreachable")
    else
      # subpath export "./fp"
      assert run("subpath", "date-fns", "^3.6.0", ~s|import {addDays} from "date-fns/fp"; console.log("sp"+typeof addDays)|) == "spfunction"
      # conditional exports (import vs require) — picks the import condition
      assert run("conditional", "nanoid", "^5.0.0", ~s|import {customAlphabet} from "nanoid"; console.log("ce"+typeof customAlphabet)|) == "cefunction"
      # subpath-pattern export "./locale/*"
      assert run("pattern", "date-fns", "^3.6.0", ~s|import enUS from "date-fns/locale/en-US"; console.log("pat"+enUS.code)|) == "paten-US"
    end
  end
end

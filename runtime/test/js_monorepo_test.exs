defmodule Workbooks.JsMonorepoTest do
  @moduledoc """
  Proves monorepo/workspaces support: `Npm.link_workspaces` reads the root `workspaces` globs and links
  member packages into node_modules so a sibling importing one by name (incl. the `workspace:*` dep
  protocol) resolves at bundle time — alongside a real external dep. Full pipeline: link → install_tree →
  esbuild bundle → run. Skips if registry unreachable.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Npm, Compilers, JsEngine}

  @root Path.expand(Path.join(__DIR__, "../compilers"))

  setup_all do
    {:ok, ready?: match?({:ok, _}, JsEngine.build_host()) and File.regular?(Path.join(@root, "esbuild/esbuild.wasm"))}
  end

  @tag :build
  @tag timeout: 120_000
  test "workspace packages link + bundle alongside an external dep", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] engines/esbuild not built")
    else
      dir = Path.join(System.tmp_dir!(), "jsmono_test")
      File.rm_rf(dir)
      File.mkdir_p!(Path.join(dir, "packages/util"))
      File.mkdir_p!(Path.join(dir, "packages/app/src"))
      File.write!(Path.join(dir, "package.json"), ~s({"name":"root","private":true,"workspaces":["packages/*"]}))
      File.write!(Path.join(dir, "packages/util/package.json"), ~s({"name":"@my/util","version":"1.0.0","main":"index.js"}))
      File.write!(Path.join(dir, "packages/util/index.js"), "export const add = (a,b) => a + b;")
      File.write!(Path.join(dir, "packages/app/package.json"), ~s({"name":"@my/app","version":"1.0.0","dependencies":{"@my/util":"workspace:*","lodash":"^4.0.0"}}))
      File.write!(Path.join(dir, "packages/app/src/main.js"), ~s|import {add} from "@my/util"; import _ from "lodash"; console.log("MONO"+add(2,3)+"."+_.capitalize("hi"))|)

      assert {:ok, linked} = Npm.link_workspaces(dir)
      assert "@my/util" in linked

      case Npm.install_tree([%{name: "lodash", req: "^4.0.0", pin: nil}], dir) do
        {:ok, _} ->
          assert {:ok, js} = Compilers.esbuild_bundle_dir(dir, "packages/app/src/main.js", [node_polyfills: true], @root)
          assert {:ok, out} = JsEngine.run_program(js)
          assert String.trim(out) == "MONO5.Hi"

        other ->
          IO.puts("\n[skip] registry unreachable: #{inspect(other) |> String.slice(0, 100)}")
      end
    end
  end
end

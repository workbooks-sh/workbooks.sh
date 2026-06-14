defmodule Workbooks.JsSsrTest do
  @moduledoc """
  Proves framework server-side rendering in-sandbox — a major real-world use case. React (react-dom/server),
  Preact (preact-render-to-string), and Vue (@vue/server-renderer, async) all render markup through the real
  pipeline. React needs a MessageChannel shim (its scheduler); the node_polyfills banner provides one.

  Skips unless engines + esbuild built and registry reachable.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Npm, Compilers, JsEngine}

  @root Path.expand(Path.join(__DIR__, "../compilers"))

  setup_all do
    {:ok, ready?: match?({:ok, _}, JsEngine.build_host()) and File.regular?(Path.join(@root, "esbuild/esbuild.wasm"))}
  end

  defp run(name, deps, main) do
    dir = Path.join(System.tmp_dir!(), "jsssr_#{name}")
    File.rm_rf(dir)
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "package.json"), ~s({"name":"t","version":"1.0.0","type":"module"}))
    File.write!(Path.join([dir, "src", "main.js"]), main)
    {:ok, _} = Npm.install_tree(Enum.map(deps, &%{name: &1, req: "*", pin: nil}), dir)

    opts = [node_polyfills: true, extra: ["--define:process.env.NODE_ENV=\"production\""]]

    with {:ok, js} <- Compilers.esbuild_bundle_dir(dir, "src/main.js", opts, @root),
         {:ok, out} <- JsEngine.run_program(js) do
      String.trim(out)
    end
  end

  @tag :build
  @tag timeout: 300_000
  test "React / Preact / Vue server-render markup in-sandbox", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] engines/esbuild not built or registry unreachable")
    else
      assert run("react", ["react", "react-dom"], ~s|import {createElement} from "react"; import {renderToStaticMarkup} from "react-dom/server"; console.log("R"+renderToStaticMarkup(createElement("div",{id:"x"},"hi")))|) == ~s|R<div id="x">hi</div>|
      assert run("preact", ["preact", "preact-render-to-string"], ~s|import {h} from "preact"; import {render} from "preact-render-to-string"; console.log("P"+render(h("span",{class:"a"},"yo")))|) == ~s|P<span class="a">yo</span>|
      assert run("vue", ["vue", "@vue/server-renderer"], ~s|import {createSSRApp,h} from "vue"; import {renderToString} from "@vue/server-renderer"; (async()=>{const app=createSSRApp({render(){return h("p",null,"v")}}); console.log("V"+await renderToString(app))})()|) == "V<p>v</p>"
    end
  end
end

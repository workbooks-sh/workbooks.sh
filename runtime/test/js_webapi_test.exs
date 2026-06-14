defmodule Workbooks.JsWebApiTest do
  @moduledoc """
  Proves Web platform APIs in-sandbox through the bundle pipeline: Web Streams (ReadableStream),
  Blob/FormData, AbortController/AbortSignal (shimmed in the node_polyfills banner — absent on
  StarlingMonkey), plus the templating lib category (handlebars/mustache).

  Skips unless engines + esbuild built and registry reachable.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Npm, Compilers, JsEngine}

  @root Path.expand(Path.join(__DIR__, "../compilers"))

  setup_all do
    {:ok, ready?: match?({:ok, _}, JsEngine.build_host()) and File.regular?(Path.join(@root, "esbuild/esbuild.wasm"))}
  end

  defp run(name, main, dep \\ nil) do
    dir = Path.join(System.tmp_dir!(), "jsweb_#{name}")
    File.rm_rf(dir)
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "package.json"), ~s({"name":"t","version":"1.0.0","type":"module"}))
    File.write!(Path.join([dir, "src", "main.js"]), main)
    if dep, do: {:ok, _} = Npm.install_tree([%{name: dep, req: "*", pin: nil}], dir)

    with {:ok, js} <- Compilers.esbuild_bundle_dir(dir, "src/main.js", [node_polyfills: true], @root),
         {:ok, out} <- JsEngine.run_program(js) do
      String.trim(out)
    end
  end

  @tag :build
  @tag timeout: 300_000
  test "Web Streams / Blob / FormData / AbortController + templating", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] engines/esbuild not built or registry unreachable")
    else
      assert run("abort", ~s|const ac=new AbortController();let f=false;ac.signal.addEventListener("abort",()=>f=true);const b0=ac.signal.aborted;ac.abort();console.log("AC"+b0+"."+ac.signal.aborted+"."+f)|) == "ACfalse.true.true"
      assert run("stream", ~s|(async()=>{const rs=new ReadableStream({start(c){c.enqueue("a");c.enqueue("b");c.close()}});const r=rs.getReader();let o="";while(true){const {done,value}=await r.read();if(done)break;o+=value}console.log("RS"+o)})()|) == "RSab"
      assert run("blob", ~s|(async()=>{const b=new Blob(["hi"],{type:"text/plain"});const f=new FormData();f.append("k","v");console.log("BF"+b.size+"."+await b.text()+"."+f.get("k"))})()|) == "BF2.hi.v"
      assert run("handlebars", ~s|import H from "handlebars"; console.log("HB"+H.compile("Hi {{name}}!")({name:"X"}))|, "handlebars") == "HBHi X!"
      assert run("mustache", ~s|import M from "mustache"; console.log("MU"+M.render("Hi {{n}}",{n:"Y"}))|, "mustache") == "MUHi Y"
    end
  end
end

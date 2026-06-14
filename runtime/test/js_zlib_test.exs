defmodule Workbooks.JsZlibTest do
  @moduledoc """
  Proves `node:zlib` in-sandbox via the node_polyfills preset (zlib→browserify-zlib): gzip + deflate
  roundtrips. Skips unless engines + esbuild built and registry reachable.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, JsEngine}

  @root Path.expand(Path.join(__DIR__, "../compilers"))

  setup_all do
    {:ok, ready?: match?({:ok, _}, JsEngine.build_host()) and File.regular?(Path.join(@root, "esbuild/esbuild.wasm"))}
  end

  defp run(name, main) do
    dir = Path.join(System.tmp_dir!(), "jszlib_#{name}")
    File.rm_rf(dir)
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "package.json"), ~s({"name":"t","version":"1.0.0","type":"module"}))
    File.write!(Path.join([dir, "src", "main.js"]), main)

    with {:ok, js} <- Compilers.esbuild_bundle_dir(dir, "src/main.js", [node_polyfills: true], @root),
         {:ok, out} <- JsEngine.run_program(js) do
      String.trim(out)
    end
  end

  @tag :build
  @tag timeout: 300_000
  test "node:zlib gzip + deflate roundtrips", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] engines/esbuild not built or registry unreachable")
    else
      assert run("gzip", ~s|import zlib from "zlib"; const gz=zlib.gzipSync(Buffer.from("hello world")); console.log("Z"+zlib.gunzipSync(gz).toString())|) == "Zhello world"
      assert run("deflate", ~s|import zlib from "zlib"; const d=zlib.deflateSync(Buffer.from("abc123")); console.log("D"+zlib.inflateSync(d).toString())|) == "Dabc123"
    end
  end
end

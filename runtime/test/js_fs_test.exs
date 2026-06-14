defmodule Workbooks.JsFsTest do
  @moduledoc """
  Proves `node:fs` in-sandbox via the node_polyfills preset (fs→memfs, an in-memory filesystem). Sync API,
  named imports, and `fs/promises` (async) all run. This is an IN-MEMORY FS (fresh per run, no host file
  access) — enough for node-authored libs that read/write a virtual or temp FS; real host-FS access is a
  separate broker concern. Skips unless engines + esbuild built and registry reachable.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, JsEngine}

  @root Path.expand(Path.join(__DIR__, "../compilers"))

  setup_all do
    {:ok, ready?: match?({:ok, _}, JsEngine.build_host()) and File.regular?(Path.join(@root, "esbuild/esbuild.wasm"))}
  end

  defp run(name, main) do
    dir = Path.join(System.tmp_dir!(), "jsfs_#{name}")
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
  test "node:fs sync + named + fs/promises (in-memory memfs)", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] engines/esbuild not built or registry unreachable")
    else
      assert run("sync", ~s|import fs from "fs"; fs.writeFileSync("/a","hi"); fs.mkdirSync("/d"); fs.writeFileSync("/d/b","x"); console.log("FS"+fs.readFileSync("/a","utf8")+"."+fs.readdirSync("/d").join(",")+"."+fs.existsSync("/a"))|) == "FShi.b.true"
      assert run("named", ~s|import {writeFileSync,readFileSync} from "fs"; writeFileSync("/z","yo"); console.log("N"+readFileSync("/z","utf8"))|) == "Nyo"
      assert run("promises", ~s|import {writeFile,readFile} from "fs/promises"; (async()=>{await writeFile("/p","async"); console.log("P"+await readFile("/p","utf8"))})()|) == "Pasync"
    end
  end
end

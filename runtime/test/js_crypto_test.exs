defmodule Workbooks.JsCryptoTest do
  @moduledoc """
  Proves the `node:crypto` surface in-sandbox via the `node_polyfills` preset (crypto→crypto-browserify,
  pure JS) plus a real crypto library (crypto-js). createHash/createHmac/randomBytes/pbkdf2 all run on
  StarlingMonkey. Skips unless the engines + esbuild are built and the registry is reachable.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Npm, Compilers, JsEngine}

  @root Path.expand(Path.join(__DIR__, "../compilers"))

  setup_all do
    {:ok, ready?: match?({:ok, _}, JsEngine.build_host()) and File.regular?(Path.join(@root, "esbuild/esbuild.wasm"))}
  end

  defp run(name, dep, req, main) do
    dir = Path.join(System.tmp_dir!(), "jscrypto_#{name}")
    File.rm_rf(dir)
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "package.json"), ~s({"name":"t","version":"1.0.0","type":"module"}))
    File.write!(Path.join([dir, "src", "main.js"]), main)
    if dep, do: {:ok, _} = Npm.install_tree([%{name: dep, req: req, pin: nil}], dir)

    with {:ok, js} <- Compilers.esbuild_bundle_dir(dir, "src/main.js", [node_polyfills: true], @root),
         {:ok, out} <- JsEngine.run_program(js) do
      String.trim(out)
    end
  end

  @tag :build
  @tag timeout: 300_000
  test "node:crypto (hash/hmac/randomBytes/pbkdf2) runs via the polyfill preset", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] engines/esbuild not built or registry unreachable")
    else
      assert run("hash", nil, nil, ~s|import c from "crypto"; console.log(c.createHash("sha256").update("a").digest("hex").slice(0,8))|) == "ca978112"
      assert run("hmac", nil, nil, ~s|import c from "crypto"; console.log(c.createHmac("sha256","k").update("a").digest("hex").length)|) == "64"
      assert run("rand", nil, nil, ~s|import c from "crypto"; console.log(c.randomBytes(8).length)|) == "8"
      assert run("pbkdf2", nil, nil, ~s|import c from "crypto"; console.log(c.pbkdf2Sync("p","s",50,16,"sha256").toString("hex").length)|) == "32"
    end
  end

  @tag :build
  @tag timeout: 300_000
  test "a real crypto library (crypto-js) runs end-to-end", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] engines/esbuild not built or registry unreachable")
    else
      assert run("cryptojs", "crypto-js", "^4.2.0", ~s|import C from "crypto-js"; console.log(C.SHA256("abc").toString().slice(0,8))|) == "ba7816bf"
    end
  end
end

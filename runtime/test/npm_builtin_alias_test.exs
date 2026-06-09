defmodule Workbooks.NpmBuiltinAliasTest do
  # wb-spy.T2.5 — bundler aliases Node builtins + node: scheme to the in-sandbox shims, prefers an
  # installed node_modules polyfill for bare names, and build-rejects native-only builtins. Proven
  # through the REAL bundle→compile→run path (the project ships NO shim copies — the bundler injects
  # them). Zero native execution.
  use ExUnit.Case, async: false

  alias Workbooks.{Compilers, PackageManager}

  defp proj(files) do
    dir = Path.join(System.tmp_dir!(), "npmalias-#{System.unique_integer([:positive])}")
    Enum.each(files, fn {rel, body} ->
      full = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, body)
    end)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  @tag :build
  @tag timeout: 300_000
  test "require('events') / require('node:crypto') / require('path') auto-resolve to shims" do
    dir =
      proj(%{
        "index.js" => ~S"""
        var EventEmitter = require("events");
        var crypto = require("node:crypto");
        var path = require("path");
        var ee = new EventEmitter(); var got = "";
        ee.on("e", function (v) { got = v; }); ee.emit("e", "fired");
        var h = crypto.createHash("sha256").update("abc").digest("hex").slice(0, 8);
        Javy.IO.writeSync(1, new TextEncoder().encode([got, h, path.basename("/a/b/c.js")].join("|")));
        """
      })

    assert {:ok, js} = Compilers.bundle_dir(dir, "index.js")
    src = Path.join(dir, "_bundle.js")
    File.write!(src, js)
    assert {:ok, wasm, _log} = Compilers.js_compile_to_wasm(src)
    assert PackageManager.run(wasm, "", []) |> String.trim() == "fired|ba7816bf|c.js"
  end

  @tag :build
  @tag timeout: 300_000
  test "an installed node_modules polyfill wins over the builtin shim for a bare name" do
    dir =
      proj(%{
        "index.js" => ~S|var u = require("util"); Javy.IO.writeSync(1, new TextEncoder().encode(u.marker));|,
        "node_modules/util/package.json" => ~S|{"name":"util","version":"9.9.9"}|,
        "node_modules/util/index.js" => ~S|module.exports = { marker: "POLYFILL" };|
      })

    assert {:ok, js} = Compilers.bundle_dir(dir, "index.js")
    src = Path.join(dir, "_bundle.js")
    File.write!(src, js)
    assert {:ok, wasm, _log} = Compilers.js_compile_to_wasm(src)
    assert PackageManager.run(wasm, "", []) |> String.trim() == "POLYFILL"
  end

  @tag :build
  @tag timeout: 300_000
  test "a native-only builtin (fs) is rejected at build time with a pointer" do
    dir = proj(%{"index.js" => ~S|var fs = require("fs"); fs.readFileSync("/x");|})

    assert {:error, {:bundle_failed, msg}} = Compilers.bundle_dir(dir, "index.js")
    assert msg =~ "Unsupported Node builtin 'fs'"
  end
end

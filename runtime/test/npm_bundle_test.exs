defmodule Workbooks.NpmBundleTest do
  # wb-spy.T1.4 — bundler-in-QuickJS. Drives the REAL path: Workbooks.Compilers.bundle_dir runs
  # bundlejob.js inside qjs-run.wasm over an on-disk node_modules tree, then the bundle is compiled
  # to wasm via the existing JS lane and executed — proving resolve→bundle→compile→run end to end
  # with zero native execution. @tag :build (needs the wasm JS toolchain).
  use ExUnit.Case, async: false

  alias Workbooks.{Compilers, PackageManager}

  defp proj(files) do
    dir = Path.join(System.tmp_dir!(), "npmbundle-#{System.unique_integer([:positive])}")
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
  test "bundles a CJS dep tree and the bundle compiles + runs to correct output" do
    # entry requires a local module AND a (hand-placed, flat) node_modules package that itself
    # requires a transitive dep — exercises relative + bare + transitive resolution.
    dir =
      proj(%{
        "index.js" => ~S|
          var greet = require("./greet");
          var upper = require("upper");
          var out = upper(greet("world"));
          Javy.IO.writeSync(1, new TextEncoder().encode(out));
        |,
        "greet.js" => ~S|module.exports = function(n){ return require("prefix") + n; };|,
        "node_modules/upper/package.json" => ~S|{"name":"upper","version":"1.0.0","main":"lib/up.js"}|,
        "node_modules/upper/lib/up.js" => ~S|module.exports = function(s){ return String(s).toUpperCase(); };|,
        "node_modules/prefix/package.json" => ~S|{"name":"prefix","version":"1.0.0"}|,
        "node_modules/prefix/index.js" => ~S|module.exports = "hi ";|
      })

    assert {:ok, js} = Compilers.bundle_dir(dir, "index.js")
    assert is_binary(js) and String.contains?(js, "__load")

    # Compile the bundled JS through the existing in-sandbox JS lane and run it.
    src = Path.join(dir, "_bundle.js")
    File.write!(src, js)
    assert {:ok, wasm, _log} = Compilers.js_compile_to_wasm(src)
    assert PackageManager.run(wasm, "", []) |> String.trim() == "HI WORLD"
  end

  @tag :build
  @tag timeout: 300_000
  test "bundles a JSON require" do
    dir =
      proj(%{
        "index.js" => ~S|
          var data = require("./data.json");
          Javy.IO.writeSync(1, new TextEncoder().encode(data.msg));
        |,
        "data.json" => ~S|{"msg":"from-json"}|
      })

    assert {:ok, js} = Compilers.bundle_dir(dir, "index.js")
    src = Path.join(dir, "_bundle.js")
    File.write!(src, js)
    assert {:ok, wasm, _log} = Compilers.js_compile_to_wasm(src)
    assert PackageManager.run(wasm, "", []) |> String.trim() == "from-json"
  end
end

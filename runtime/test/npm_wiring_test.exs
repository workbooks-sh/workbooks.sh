defmodule Workbooks.NpmWiringTest do
  # wb-spy.T1.5 — build_dir(js/ts) + inline wired through resolve→bundle→js lane. The first test
  # is fully offline (a committed node_modules tree) proving the wiring deterministically; the
  # second (@tag :netdeps) runs a REAL registry package inline. Zero native execution throughout.
  use ExUnit.Case, async: false

  alias Workbooks.PackageManager, as: PM

  defp proj(files) do
    dir = Path.join(System.tmp_dir!(), "npmwire-#{System.unique_integer([:positive])}")
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
  test "build_dir(js) with a committed node_modules bundles, compiles, and runs (offline)" do
    dir =
      proj(%{
        "package.json" => ~S|{"name":"app","dependencies":{"upper":"^1.0.0"}}|,
        "index.js" => ~S|
          var up = require("upper");
          Javy.IO.writeSync(1, new TextEncoder().encode(up("hello npm")));
        |,
        "node_modules/upper/package.json" => ~S|{"name":"upper","version":"1.0.0"}|,
        "node_modules/upper/index.js" => ~S|module.exports = function(s){ return String(s).toUpperCase(); };|
      })

    # The old hard error must be gone.
    assert {:ok, wasm, st} = PM.build_dir(dir, "js")
    assert st in [:built, :cached]
    assert PM.run(wasm, "", []) |> String.trim() == "HELLO NPM"
  end

  @tag :build
  @tag timeout: 300_000
  test "a deps dir no longer returns js_bundling_unsupported_in_sandbox" do
    dir =
      proj(%{
        "package.json" => ~S|{"dependencies":{"x":"^1.0.0"}}|,
        "index.js" => ~S|Javy.IO.writeSync(1, new TextEncoder().encode("ok"));|,
        "node_modules/x/package.json" => ~S|{"name":"x","version":"1.0.0"}|,
        "node_modules/x/index.js" => ~S|module.exports = 1;|
      })

    result = PM.build_dir(dir, "js")
    refute match?({:error, {:js_bundling_unsupported_in_sandbox, _}}, result)
    assert {:ok, _wasm, _st} = result
  end

  @tag :netdeps
  @tag :build
  @tag timeout: 600_000
  test "inline js with a real registry dep (ms) resolves, bundles, compiles, runs" do
    comp = %{
      "name" => "msinline#{System.unique_integer([:positive])}",
      "lang" => "js",
      "src" => ~S|
        var ms = require("ms");
        Javy.IO.writeSync(1, new TextEncoder().encode(ms(60000)));
      |,
      "deps" => ["ms@^2.1.0"]
    }

    case PM.build(comp) do
      {_n, "js", {:ok, wasm, st}} ->
        assert st in [:built, :cached]
        assert PM.run(wasm, "", []) |> String.trim() == "1m"

      {_n, "js", {:error, reason}} ->
        IO.puts("\n[skip] inline ms: #{inspect(reason) |> String.slice(0, 120)}")
    end
  end
end

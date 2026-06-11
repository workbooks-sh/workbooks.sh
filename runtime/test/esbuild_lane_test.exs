defmodule Workbooks.EsbuildLaneTest do
  use ExUnit.Case, async: false

  # wb-feto: the esbuild lane — esbuild compiled to wasip1, run under wasmtime
  # (which JITs it to native). The keystone fix for the in-sandbox build perf wall:
  # a bundle that takes ~23 min interpreting in QuickJS runs in ~160 ms here.
  # @tag :build — needs the esbuild.wasm artifact (gitignored, staged into the
  # compilers package); run with `--include build`.

  @moduletag :build
  @root Path.expand("../compilers", __DIR__)   # runtime/compilers (esbuild/esbuild.wasm)

  defp fixture(files) do
    dir = Path.join(System.tmp_dir!(), "eb-#{System.unique_integer([:positive])}")
    for {p, b} <- files do
      f = Path.join(dir, p)
      File.mkdir_p!(Path.dirname(f))
      File.write!(f, b)
    end
    dir
  end

  test "bundles a multi-file TS+JS project natively-fast, TS stripped" do
    dir =
      fixture(%{
        "package.json" => ~S|{"name":"p","version":"1.0.0"}|,
        "src/util.ts" => "export const add = (a: number, b: number): number => a + b;\n",
        "src/main.js" => "import { add } from './util.ts';\nexport const total = add(40, 2);\n"
      })

    t0 = System.monotonic_time(:millisecond)
    res = Workbooks.Compilers.esbuild_bundle_dir(dir, "src/main.js", [], @root)
    dt = System.monotonic_time(:millisecond) - t0

    assert {:ok, js} = res
    assert js =~ "total"
    assert js =~ "add"
    refute js =~ ": number", "TS types should be stripped"
    assert dt < 10_000, "esbuild should be ~sub-second; took #{dt}ms"
    IO.puts("\n[esbuild] multi-file TS+JS bundle in #{dt}ms")
    File.rm_rf!(dir)
  end

  test "transpiles JSX" do
    dir =
      fixture(%{
        "package.json" => ~S|{"name":"p"}|,
        "src/main.jsx" => "export const A = () => <div className=\"x\">{40 + 2}</div>;\n"
      })

    assert {:ok, js} = Workbooks.Compilers.esbuild_bundle_dir(dir, "src/main.jsx", [jsx: "transform"], @root)
    assert js =~ "createElement"
    File.rm_rf!(dir)
  end
end

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

  test "bundle_dir routes a pure-compute project through esbuild (fast path)" do
    dir =
      fixture(%{
        "package.json" => ~S|{"name":"p"}|,
        "src/u.js" => "export const add = (a, b) => a + b;\n",
        "src/main.js" => "import { add } from './u.js';\nexport const t = add(1, 2);\n"
      })

    t0 = System.monotonic_time(:millisecond)
    assert {:ok, js} = Workbooks.Compilers.bundle_dir(dir, "src/main.js", [], @root)
    dt = System.monotonic_time(:millisecond) - t0
    assert js =~ "add"
    assert dt < 10_000, "bundle_dir should take the esbuild fast path; took #{dt}ms"
    IO.puts("\n[bundle_dir→esbuild] #{dt}ms")
    File.rm_rf!(dir)
  end

  @tag timeout: 1_800_000
  test "svelte_bundle_dir splits compile (QuickJS) from bundle (esbuild), correct output" do
    dir =
      fixture(%{
        "package.json" => ~S|{"name":"p","dependencies":{"svelte":"^4.2.0"}}|,
        "Counter.svelte" => "<script>let n = 0;</script>\n<button on:click={() => n++}>count {n}</button>\n",
        "src/main.js" => "import Counter from '../Counter.svelte';\nexport { Counter };\n"
      })

    # install svelte (npm lane) — fast (~3s). install_tree returns {:ok, installed}
    # OR {:ok, installed, errors} when optional/transitive deps fail (e.g. @types/*);
    # svelte itself still lands — that's what we check.
    Workbooks.Npm.install_tree([%{name: "svelte", req: "^4.2.0", pin: nil}], dir)
    assert File.dir?(Path.join(dir, "node_modules/svelte"))

    t0 = System.monotonic_time(:millisecond)
    res = Workbooks.Compilers.svelte_bundle_dir(dir, "src/main.js", [], @root)
    dt = System.monotonic_time(:millisecond) - t0

    assert {:ok, js} = res
    refute js =~ "on:click", "raw svelte template syntax should be compiled away"
    assert byte_size(js) > 500 and (js =~ "create_fragment" or js =~ "function"),
           "looks like compiled+bundled svelte output"
    IO.puts("\n[svelte split] compile(QuickJS)+bundle(esbuild) total = #{dt}ms")
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

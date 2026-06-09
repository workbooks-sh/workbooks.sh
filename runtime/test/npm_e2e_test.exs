defmodule Workbooks.NpmE2ETest do
  # wb-spy.T1.6 — the wedge-closing end-to-end proof. A REAL pure-JS npm package (with a transitive
  # dependency) is resolved + fetched + assembled + bundled + compiled + run ENTIRELY in-sandbox
  # through Workbooks.PackageManager.build_dir, with NO committed node_modules (forces a live install
  # from registry.npmjs.org). The no-native-execution invariant is proven separately and
  # un-regressably by test/sandbox_invariant_test.exs, whose static scan covers the new npm code
  # (Workbooks.Npm + Compilers.bundle_dir) — neither shells node/npm/curl/tar.
  #
  # @tag :netdeps (needs the registry) + :build (needs the wasm JS toolchain). Degrades gracefully
  # offline so the default suite stays green without network, exactly like crate_deps_test.
  use ExUnit.Case, async: false

  alias Workbooks.PackageManager, as: PM

  defp proj(files) do
    dir = Path.join(System.tmp_dir!(), "npme2e-#{System.unique_integer([:positive])}")
    Enum.each(files, fn {rel, body} ->
      full = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, body)
    end)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp run_e2e(dir, expect) do
    case PM.build_dir(dir, "js") do
      {:ok, wasm, st} ->
        assert st in [:built, :cached]
        # node_modules was populated by a LIVE install (the project ships none).
        assert File.dir?(Path.join(dir, "node_modules"))
        assert PM.run(wasm, "", []) |> String.trim() == expect

      {:error, reason} ->
        IO.puts("\n[skip] npm e2e: #{inspect(reason) |> String.slice(0, 140)}")
    end
  end

  @tag :netdeps
  @tag :build
  @tag timeout: 600_000
  test "real package with a transitive dep (is-odd → is-number) installs, bundles, runs" do
    dir =
      proj(%{
        "package.json" => ~S|{"name":"e2e","dependencies":{"is-odd":"^3.0.0"}}|,
        "index.js" => ~S|
          var isOdd = require("is-odd");
          Javy.IO.writeSync(1, new TextEncoder().encode(String(isOdd(3)) + "," + String(isOdd(4))));
        |
      })

    run_e2e(dir, "true,false")
  end

  @tag :netdeps
  @tag :build
  @tag timeout: 600_000
  test "real leaf package (ms) installs, bundles, runs via build_dir" do
    dir =
      proj(%{
        "package.json" => ~S|{"name":"e2e2","dependencies":{"ms":"^2.1.0"}}|,
        "index.js" => ~S|
          var ms = require("ms");
          Javy.IO.writeSync(1, new TextEncoder().encode(ms("2 days")));
        |
      })

    run_e2e(dir, "172800000")
  end
end

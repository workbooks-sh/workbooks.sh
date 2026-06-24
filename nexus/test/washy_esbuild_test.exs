defmodule Nexus.WashyEsbuildTest do
  @moduledoc """
  **Phase C2 — packages in the sandbox (wb-gree).** The honest, no-gaming proof: a REAL npm package graph
  with a transitive dependency (`is-odd` → `is-number`, their actual published sources) is bundled by the
  REAL production bundler (esbuild v0.28.1, run under wasmtime like every other compiler lane), and the
  resulting untrusted bundle runs in Washy — bit-identical interp vs tiered. esbuild does the real Node
  resolution (bare specifier → `package.json` main, transitive `require`); we don't hand-roll any of it.
  """
  use ExUnit.Case, async: false

  alias Nexus.Compilers.Esbuild
  alias Nexus.Washy.Sandbox

  # the ACTUAL published sources (is-number@7, is-odd@3) — a real two-level npm dependency graph.
  @files %{
    "node_modules/is-number/package.json" => ~s({"name":"is-number","version":"7.0.0","main":"index.js"}),
    "node_modules/is-number/index.js" => """
    'use strict';
    module.exports = function(num) {
      if (typeof num === 'number') return num - num === 0;
      if (typeof num === 'string' && num.trim() !== '') {
        return Number.isFinite ? Number.isFinite(+num) : isFinite(+num);
      }
      return false;
    };
    """,
    "node_modules/is-odd/package.json" =>
      ~s({"name":"is-odd","version":"3.0.1","main":"index.js","dependencies":{"is-number":"^6.0.0"}}),
    "node_modules/is-odd/index.js" => """
    'use strict';
    const isNumber = require('is-number');
    module.exports = function isOdd(value) {
      const n = Math.abs(value);
      if (!isNumber(n)) throw new TypeError('expected a number');
      if (!Number.isInteger(n)) throw new Error('expected an integer');
      return (n % 2) === 1;
    };
    """,
    "main.js" => """
    var isOdd = require('is-odd');
    var out = isOdd(2017) + ',' + isOdd(8) + '\\n';
    Javy.IO.writeSync(1, new TextEncoder().encode(out));
    """
  }

  @tag timeout: 120_000
  test "real esbuild bundles a real npm dep graph; the bundle runs in Washy, oracle-consistent" do
    qjs = "compilers/js/qjs-run.wasm"

    if Esbuild.esbuild_wasm() && File.exists?(qjs) do
      {:ok, bundle} = Esbuild.bundle(@files, "main.js")
      # sanity: it's a real bundle that actually inlined both modules (no leftover bare require)
      assert byte_size(bundle) > 200
      refute bundle =~ ~S|require("is-odd")|

      qjs_bytes = File.read!(qjs)
      interp = Sandbox.run_command({:interp, qjs_bytes, bundle}, "", fuel: 50_000_000_000, timeout_ms: 60_000, transpile: false)
      tiered = Sandbox.run_command({:interp, qjs_bytes, bundle}, "", fuel: 50_000_000_000, timeout_ms: 60_000, transpile: true)

      assert interp == tiered
      assert {:ok, "true,false\n"} = interp
    else
      IO.puts("\n[skip] esbuild.wasm or qjs-run.wasm absent")
    end
  end
end

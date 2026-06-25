defmodule Nexus.WashyRollupBundleTest do
  @moduledoc """
  **Rollup 4 runs a full bundle on Washy's QuickJS, byte-identical to native Node (the vite-CLI path).**

  This is the integration above `washy_rollup_parser_test.exs`: the entire **Rollup 4 JavaScript**
  (`@rollup/wasm-node`, ~1.27 MB bundled to CJS) runs on our QuickJS engine; its native `parse()` is
  routed out via `__host('rollup_parse', …)` → `Nexus.Washy.HostRollup` → the **Rust wasm parser running
  as a sibling Washy module**. Two wasm modules cooperating through the host — no Node-in-wasm, no
  wasm-in-QuickJS.

  The fixture `rollup_bundle.cjs` performs a real `rollup.rollup({input, plugins}).generate({cjs})` over
  a virtual module and prints `BUNDLE_OK[<code>]`. We assert the emitted bundle is byte-identical to what
  native `@rollup/wasm-node` produces on Node (`rollup_bundle_golden.js`). `shim_prelude.js` supplies the
  few Node-surface gaps Rollup needs that aren't yet baked into `compilers/js/node/` (fs/promises,
  path.win32, process.once/off) — a runtime overlay until those land in the compiled shims.

  The fixture uses `treeshake:true` (Rollup's default) over `const x = 1 + 2; export const y = x * 10;`
  — so this also proves the tree-shaking analysis runs correctly on Washy (it keeps the used binding `x`
  and the export `y`, byte-exact to node).
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy

  @dir Path.join(__DIR__, "conformance/rollup")
  @qjs Path.join(__DIR__, "../compilers/js/qjs-run.wasm")

  @tag timeout: 300_000
  test "Rollup 4 bundles on Washy QuickJS via the host-routed Rust parser; output == native node" do
    prelude = File.read!(Path.join(@dir, "shim_prelude.js"))
    bundle = File.read!(Path.join(@dir, "rollup_bundle.cjs"))
    golden = File.read!(Path.join(@dir, "rollup_bundle_golden.js"))
    js = prelude <> "\n" <> bundle

    {:ok, out} =
      Washy.Sandbox.run_command({:interp, @qjs, js}, "",
        fuel: 8_000_000_000_000, timeout_ms: 240_000)

    assert out =~ "BUNDLE_OK[", "Rollup build must complete on QuickJS; got: #{String.slice(out, 0, 400)}"

    # extract the emitted bundle between BUNDLE_OK[ … ] (the trailing ] is the last char printed)
    [_, rest] = String.split(out, "BUNDLE_OK[", parts: 2)
    code = String.replace_suffix(String.trim_trailing(rest, "\n"), "]", "")

    assert code == golden,
           "Washy-Rollup output must be byte-identical to native node.\n--- washy ---\n#{code}\n--- golden ---\n#{golden}"
  end
end

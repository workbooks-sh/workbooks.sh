defmodule Workbooks.JsNodeBootstrapTest do
  @moduledoc """
  SLICE 0 gate (wb-b9xv) — the Node-compat bootstrap on `Workbooks.JsEngine`.

  StarlingMonkey gives the web-platform half (fetch / WebCrypto / TextEncoder / modern ES) but NO
  `process` / `require` / `module` / `Buffer` / `node:` resolver — a Node-shaped script dies on line 1
  ("require is not defined"). `JsEngine.run_node/2` prepends a pure-JS prelude (CommonJS require +
  host-injectable process + a `node:`/bare resolver over the embedded shims) so the script loads.

  This test asserts the SLICE 0 contract empirically on the LIVE engine:
    * `require('node:path')` resolves and `path.join('a','b') === 'a/b'`
    * `process.argv` / `process.env` carry the host-injected values
    * `process.exit(n)` surfaces as `exit_code`
    * a `node:` builtin that is OUT OF SCOPE (`fs`) throws "Cannot find module" (no silent fake)
    * (network, separately gated) an async `fetch` runs through the allow_http path

  Tags:
    * `:build`   — needs the SM eval-host (`build/cache/jsengine/eval-host-023.wasm`). Skips otherwise.
    * `:netdeps` — the fetch case additionally needs outbound HTTP; degrades to a skip offline.
  """
  use ExUnit.Case, async: false
  alias Workbooks.JsEngine

  setup_all do
    {:ok, ready?: match?({:ok, _}, JsEngine.build_host())}
  end

  @tag :build
  @tag timeout: 60_000
  test "require('node:path') + host-injected process work on the live engine", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] SM eval-host not built (build/cache/jsengine/eval-host-023.wasm)")
    else
      src = ~S"""
      const path = require('node:path');
      process.stdout.write('join=' + path.join('a','b') + '\n');
      process.stdout.write('eq=' + (path.join('a','b') === 'a/b') + '\n');
      process.stdout.write('argv2=' + process.argv[2] + '\n');
      process.stdout.write('envFOO=' + process.env.FOO + '\n');
      process.stdout.write('globalProcess=' + (globalThis.process === process) + '\n');
      """

      assert {:ok, %{stdout: out, exit_code: 0}} =
               JsEngine.run_node(src,
                 env: %{"FOO" => "bar"},
                 argv: ["node", "script", "ARGV_OK"]
               )

      assert out =~ "join=a/b"
      assert out =~ "eq=true"
      assert out =~ "argv2=ARGV_OK"
      assert out =~ "envFOO=bar"
      assert out =~ "globalProcess=true"
    end
  end

  @tag :build
  @tag timeout: 60_000
  test "process.exit(n) surfaces as exit_code", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] SM eval-host not built")
    else
      assert {:ok, %{exit_code: 3}} =
               JsEngine.run_node("process.stdout.write('hi'); process.exit(3);")
    end
  end

  @tag :build
  @tag timeout: 60_000
  test "out-of-scope node: builtins throw 'Cannot find module' (no silent fake)", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] SM eval-host not built")
    else
      assert {:error, {:node_eval_failed, msg}} =
               JsEngine.run_node("require('node:fs');")

      assert msg =~ "Cannot find module"
    end
  end

  # The async fetch half of the SLICE 0 gate. `run_node`'s user-script wrapper is synchronous, so the
  # awaited fetch is proven directly on `JsEngine.eval/2` (whose async bootstrap awaits the returned
  # thenable, driving StarlingMonkey's event loop until the fetch settles) — sharing the exact prelude +
  # require + host-injected `process` path. This is the same allow_http route every Instance uses.
  @tag :build
  @tag :netdeps
  @tag timeout: 120_000
  test "require + process + AWAITED fetch run end-to-end through allow_http", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] SM eval-host not built")
    else
      root = Path.expand(Path.join(__DIR__, ".."))
      prelude = File.read!(Path.join(root, "compilers/js/node-prelude.js"))
      path_shim = File.read!(Path.join(root, "compilers/js/shims/path.js"))

      boot =
        Jason.encode!(%{
          "shims" => %{"path" => path_shim},
          "env" => %{"FOO" => "bar"},
          "argv" => ["node", "script", "ARGV_OK"]
        })

      payload =
        "globalThis.__wbNode=" <>
          boot <>
          ";\n" <>
          prelude <>
          "\n" <>
          ~S"""
          (async () => {
            const path = require('node:path');
            const out = {};
            out.pathEq = (path.join('a','b') === 'a/b');
            out.argv2 = process.argv[2];
            out.envFOO = process.env.FOO;
            try {
              const res = await fetch('https://example.com');
              out.fetchStatus = res.status;
              const body = await res.text();
              out.fetchHasExample = /Example Domain/.test(body);
            } catch (e) {
              out.fetchErr = (e && e.message) ? e.message : String(e);
            }
            return JSON.stringify(out);
          })()
          """

      case JsEngine.eval(payload, timeout: 60_000) do
        {:ok, json} ->
          case Jason.decode(json) do
            {:ok, %{"fetchErr" => err}} ->
              IO.puts("\n[skip] network unreachable (#{err})")

            {:ok, %{"fetchStatus" => status} = m} ->
              # require + process still proven even when network is up:
              assert m["pathEq"] == true
              assert m["argv2"] == "ARGV_OK"
              assert m["envFOO"] == "bar"
              assert status == 200
              assert m["fetchHasExample"] == true

            other ->
              flunk("unexpected eval JSON: #{inspect(other)}")
          end

        other ->
          flunk("eval: #{inspect(other)}")
      end
    end
  end
end

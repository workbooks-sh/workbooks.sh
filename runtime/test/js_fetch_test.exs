defmodule Workbooks.JsFetchTest do
  @moduledoc """
  Proves the web-platform HTTP surface in-sandbox: URL/URLSearchParams/Headers/Request (StarlingMonkey
  globals) and brokered `fetch` (guest fetch → StarlingMonkey wasi:http → NetGuard, SSRF-safe). `fetch`
  unblocks the HTTP-client library category — proven here end-to-end with `ky` (a real fetch-based client).

  run_program's capture instruments fetch with an in-flight counter so the idle-drain waits out network
  latency instead of returning during the quiet gap before the response arrives.

  Network test — skips unless the engines are built AND the request succeeds (offline/CI-firewalled → skip).
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Npm, Compilers, JsEngine}

  @root Path.expand(Path.join(__DIR__, "../compilers"))

  setup_all do
    {:ok, ready?: match?({:ok, _}, JsEngine.build_host()) and File.regular?(Path.join(@root, "esbuild/esbuild.wasm"))}
  end

  defp bundle_run(dir, main, opts \\ [node_polyfills: true]) do
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "package.json"), ~s({"name":"t","version":"1.0.0","type":"module"}))
    File.write!(Path.join([dir, "src", "main.js"]), main)

    with {:ok, js} <- Compilers.esbuild_bundle_dir(dir, "src/main.js", opts, @root),
         {:ok, out} <- JsEngine.run_program(js) do
      String.trim(out)
    end
  end

  @tag :build
  @tag timeout: 60_000
  test "URL / URLSearchParams / Headers / Request are present (no network)", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] engines not built")
    else
      dir = Path.join(System.tmp_dir!(), "jsfetch_url")
      File.rm_rf(dir)
      out = bundle_run(dir, ~s<console.log(new URL("https://a.com/p?q=1").pathname+"|"+new URLSearchParams("a=1&a=3").getAll("a").join(",")+"|"+new Headers({"x":"7"}).get("x"))>)
      assert out =~ "/p|1,3|7"
    end
  end

  @tag :build
  @tag timeout: 120_000
  test "brokered fetch + a real HTTP client (ky) run end-to-end", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] engines not built")
    else
      d1 = Path.join(System.tmp_dir!(), "jsfetch_raw")
      File.rm_rf(d1)
      raw = bundle_run(d1, ~s|(async()=>{const r=await fetch("https://example.com");const t=await r.text();console.log("F"+r.status+(t.indexOf("Example Domain")>=0))})()|)

      if raw == "" do
        IO.puts("\n[skip] network unreachable (fetch returned no output)")
      else
        assert raw =~ "F200true"

        d2 = Path.join(System.tmp_dir!(), "jsfetch_ky")
        File.rm_rf(d2)
        File.mkdir_p!(d2)
        assert {:ok, _} = Npm.install_tree([%{name: "ky", req: "^1.0.0", pin: nil}], d2)
        ky = bundle_run(d2, ~s|import ky from "ky";(async()=>{const t=await ky.get("https://example.com").text();console.log("ky"+(t.indexOf("Example Domain")>=0))})()|)
        assert ky =~ "kytrue"
      end
    end
  end
end

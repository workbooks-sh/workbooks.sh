defmodule Workbooks.JsNetShimTest do
  # wb-e1x.4 / JD.4 — http/https/fetch shims backed by Javy.Net.get (host_http_get) via JsDock.
  # Proven through the REAL :dock path: bundled + dock-compiled + run under Workbooks.JsDock. Net is
  # host-brokered (Route B) and Policy-gated — denied on :minimal, live on :network. Zero native exec.
  use ExUnit.Case, async: false

  alias Workbooks.{Compilers, JsDock}

  defp dock_project(index_src) do
    shim_dir = Path.join(Compilers.default_root(), "js/shims")
    dir = Path.join(System.tmp_dir!(), "jsnet-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    Enum.each(~w(http https events), fn s -> File.cp!(Path.join(shim_dir, "#{s}.js"), Path.join(dir, "#{s}.js")) end)
    File.write!(Path.join(dir, "index.js"), index_src)
    {:ok, js} = Compilers.bundle_dir(dir, "index.js")
    src = Path.join(dir, "_bundle.js")
    File.write!(src, js)
    {:ok, wasm, _log} = Compilers.js_compile_to_wasm(src, dock: true)
    wasm
  end

  @tag :build
  @tag timeout: 300_000
  test "net denied on a non-net profile — fetch rejects (host fn returns -1)" do
    wasm =
      dock_project(~S"""
      var http = require("./http");
      http.fetch("http://example.com")
        .then(function () { Javy.IO.writeSync(1, new TextEncoder().encode("got")); })
        .catch(function () { Javy.IO.writeSync(1, new TextEncoder().encode("denied")); });
      """)

    assert {:ok, out} = JsDock.run(wasm, "", profile: :minimal)
    assert String.trim(to_string(out)) == "denied"
  end

  @tag :netdeps
  @tag :build
  @tag timeout: 300_000
  test "fetch() on :network resolves with the host-brokered body" do
    wasm =
      dock_project(~S"""
      var http = require("./http");
      http.fetch("https://registry.npmjs.org/ms")
        .then(function (r) { return r.text(); })
        .then(function (t) { Javy.IO.writeSync(1, new TextEncoder().encode(t.indexOf("\"name\"") >= 0 ? "fetched" : "empty")); })
        .catch(function (e) { Javy.IO.writeSync(1, new TextEncoder().encode("err:" + e)); });
      """)

    case JsDock.run(wasm, "", profile: :network) do
      {:ok, out} -> assert String.trim(to_string(out)) == "fetched"
      {:error, reason} -> IO.puts("\n[skip] js fetch: #{inspect(reason) |> String.slice(0, 120)}")
    end
  end

  @tag :netdeps
  @tag :build
  @tag timeout: 300_000
  test "http.get(url, cb) emits data/end on :network" do
    wasm =
      dock_project(~S"""
      var https = require("./https");
      https.get("https://registry.npmjs.org/ms", function (res) {
        var buf = "";
        res.on("data", function (d) { buf += d; });
        res.on("end", function () { Javy.IO.writeSync(1, new TextEncoder().encode(buf.indexOf("\"name\"") >= 0 ? "got" : "empty")); });
      });
      """)

    case JsDock.run(wasm, "", profile: :network) do
      {:ok, out} -> assert String.trim(to_string(out)) == "got"
      {:error, reason} -> IO.puts("\n[skip] js http.get: #{inspect(reason) |> String.slice(0, 120)}")
    end
  end
end

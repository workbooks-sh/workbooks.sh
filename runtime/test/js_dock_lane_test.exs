defmodule Workbooks.JsDockLaneTest do
  # wb-e1x.5 / JD.5 — lane routing end to end. A bundle that uses fs/net is auto dock-compiled and
  # PackageManager.run routes it to JsDock (detected from env.host_* imports); a pure-compute bundle
  # stays on the CLI lane. Proven through the real build_dir → run path. Zero native execution.
  use ExUnit.Case, async: false

  alias Workbooks.PackageManager, as: PM

  defp proj(files) do
    dir = Path.join(System.tmp_dir!(), "jsdocklane-#{System.unique_integer([:positive])}")
    Enum.each(files, fn {rel, body} ->
      full = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, body)
    end)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # A committed node_modules dep so js_dir_has_deps? triggers the npm bundle path (offline).
  defp with_dep(extra) do
    Map.merge(
      %{
        "package.json" => ~S|{"name":"app","dependencies":{"dep":"*"}}|,
        "node_modules/dep/package.json" => ~S|{"name":"dep","version":"1.0.0"}|,
        "node_modules/dep/index.js" => ~S|module.exports = "DEP";|
      },
      extra
    )
  end

  @tag :build
  @tag timeout: 300_000
  test "a bundle using fs is dock-compiled and run() auto-routes to JsDock (VFS-backed)" do
    dir =
      proj(
        with_dep(%{
          "index.js" => ~S"""
          var fs = require("fs");
          var dep = require("dep");
          fs.writeFileSync("/x", "dock-" + dep);
          Javy.IO.writeSync(1, new TextEncoder().encode(fs.readFileSync("/x", "utf8")));
          """
        })
      )

    assert {:ok, wasm, _st} = PM.build_dir(dir, "js")
    # No explicit lane — run() detects the dock artifact and routes to JsDock (minimal: vfs ok).
    assert PM.run(wasm, "") |> to_string() |> String.trim() == "dock-DEP"
  end

  @tag :build
  @tag timeout: 300_000
  test "a pure-compute bundle stays on the CLI lane (no dock)" do
    dir =
      proj(
        with_dep(%{
          "index.js" => ~S|var dep = require("dep"); Javy.IO.writeSync(1, new TextEncoder().encode("pure-" + dep));|
        })
      )

    assert {:ok, wasm, _st} = PM.build_dir(dir, "js")
    # Not a dock artifact → CLI lane.
    refute File.read!(wasm) =~ "host_vfs_read"
    assert PM.run(wasm, "") |> to_string() |> String.trim() == "pure-DEP"
  end

  @tag :build
  @tag timeout: 300_000
  test "a bundle using http builds (dock) but net is denied on the default minimal profile" do
    dir =
      proj(
        with_dep(%{
          "index.js" => ~S"""
          var http = require("http");
          require("dep");
          http.fetch("http://example.com")
            .then(function () { Javy.IO.writeSync(1, new TextEncoder().encode("got")); })
            .catch(function () { Javy.IO.writeSync(1, new TextEncoder().encode("denied")); });
          """
        })
      )

    assert {:ok, wasm, _st} = PM.build_dir(dir, "js")
    assert File.read!(wasm) =~ "host_http_get"
    # default profile :minimal has no net → denied (deterministic; live net is in js_net_shim_test)
    assert PM.run(wasm, "") |> to_string() |> String.trim() == "denied"
  end
end

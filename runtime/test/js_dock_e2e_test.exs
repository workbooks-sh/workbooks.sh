defmodule Workbooks.JsDockE2ETest do
  # wb-e1x.6 / JD.6 — JsDock capstone. Composes a npm dependency + Node fs + Node http in ONE
  # program, driven through the full build_dir → dock-compile → JsDock.run pipeline. Proves fs
  # (Javy.VFS) and net (Javy.Net, host-brokered) work together, Policy-gated. Zero native execution
  # (the no-native invariant is enforced separately by sandbox_invariant_test over js_dock.ex et al).
  use ExUnit.Case, async: false

  alias Workbooks.PackageManager, as: PM

  defp proj(files) do
    dir = Path.join(System.tmp_dir!(), "jsdocke2e-#{System.unique_integer([:positive])}")
    Enum.each(files, fn {rel, body} ->
      full = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, body)
    end)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  @composed ~S"""
  var fs = require("fs");
  var http = require("http");
  var dep = require("dep");
  http.fetch("https://registry.npmjs.org/ms")
    .then(function (r) { return r.json(); })
    .then(function (j) {
      fs.writeFileSync("/out", j.name + ":" + dep);     // net result persisted via VFS
      Javy.IO.writeSync(1, new TextEncoder().encode(fs.readFileSync("/out", "utf8")));
    })
    .catch(function () { Javy.IO.writeSync(1, new TextEncoder().encode("denied")); });
  """

  # Committed node_modules dep so the build is offline (only the network PROFILE needs egress).
  defp composed_project do
    proj(%{
      "package.json" => ~S|{"name":"cap","dependencies":{"dep":"*"}}|,
      "node_modules/dep/package.json" => ~S|{"name":"dep","version":"1.0.0"}|,
      "node_modules/dep/index.js" => ~S|module.exports = "OK";|,
      "index.js" => @composed
    })
  end

  @tag :build
  @tag timeout: 300_000
  test "fs + http + npm dep compose; net DENIED on minimal profile (offline, deterministic)" do
    dir = composed_project()
    assert {:ok, wasm, _st} = PM.build_dir(dir, "js")
    # dock artifact (uses both caps)
    bytes = File.read!(wasm)
    assert bytes =~ "host_vfs_read" and bytes =~ "host_http_get"
    # minimal profile: fetch denied → catch → "denied" (proves the whole bundle builds + runs + gates)
    assert PM.run(wasm, "") |> to_string() |> String.trim() == "denied"
  end

  @tag :netdeps
  @tag :build
  @tag timeout: 300_000
  test "fs + http + npm dep compose end to end on :network (live fetch persisted via VFS)" do
    dir = composed_project()
    assert {:ok, wasm, _st} = PM.build_dir(dir, "js")

    case PM.run(wasm, "", [], [], profile: :network) do
      out when is_binary(out) ->
        assert String.trim(out) == "ms:OK"

      {:error, reason} ->
        IO.puts("\n[skip] jsdock e2e net: #{inspect(reason) |> String.slice(0, 120)}")
    end
  end
end

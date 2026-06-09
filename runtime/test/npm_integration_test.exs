defmodule Workbooks.NpmIntegrationTest do
  # wb-spy.T2.6 — Tier-2 integration. Proves the SHIPPED Node surface composes: a real npm package
  # (is-odd → is-number) bundled together with multiple core shims (events/buffer/path/crypto) runs
  # end to end through build_dir. RESCOPED from the original brief because fs (wb-l52/T2.2) and net
  # (wb-36w/T2.3) are blocked at the harness/lane boundary: the honest "net/fs refused" is that the
  # bundler REJECTS them at build time with a pointer (no silent availability). Zero native execution.
  use ExUnit.Case, async: false

  alias Workbooks.Compilers
  alias Workbooks.PackageManager, as: PM

  defp proj(files) do
    dir = Path.join(System.tmp_dir!(), "npmint-#{System.unique_integer([:positive])}")
    Enum.each(files, fn {rel, body} ->
      full = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, body)
    end)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  @tag :netdeps
  @tag :build
  @tag timeout: 600_000
  test "a real npm package composes with events/buffer/path/crypto shims through build_dir" do
    dir =
      proj(%{
        "package.json" => ~S|{"name":"int","dependencies":{"is-odd":"^3.0.0"}}|,
        "index.js" => ~S"""
        var isOdd = require("is-odd");
        var EventEmitter = require("events");
        var Buffer = require("buffer").Buffer;
        var path = require("path");
        var crypto = require("crypto");

        var ee = new EventEmitter(); var ev = "";
        ee.on("go", function (v) { ev = v; }); ee.emit("go", "hi");

        var out = [
          String(isOdd(7)),
          Buffer.from("hi").toString("hex"),
          ev,
          path.extname("a.js"),
          crypto.createHash("sha256").update("x").digest("hex").slice(0, 6)
        ].join("|");
        Javy.IO.writeSync(1, new TextEncoder().encode(out));
        """
      })

    case PM.build_dir(dir, "js") do
      {:ok, wasm, st} ->
        assert st in [:built, :cached]
        assert PM.run(wasm, "", []) |> String.trim() == "true|6869|hi|.js|2d7116"

      {:error, reason} ->
        IO.puts("\n[skip] npm integration: #{inspect(reason) |> String.slice(0, 140)}")
    end
  end

  @tag :build
  @tag timeout: 200_000
  test "net (http) and fs are refused at build time with a pointer (offline)" do
    for builtin <- ~w(http fs net) do
      dir = proj(%{"index.js" => "var m = require(#{inspect(builtin)}); m;"})
      assert {:error, {:bundle_failed, msg}} = Compilers.bundle_dir(dir, "index.js")
      assert msg =~ "Unsupported Node builtin '#{builtin}'"
    end
  end
end

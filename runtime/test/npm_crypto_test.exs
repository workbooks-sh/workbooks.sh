defmodule Workbooks.NpmCryptoTest do
  # wb-spy.T2.4 — crypto + timers shims, proven through the REAL compile+run path. Asserts known
  # SHA-256 / SHA-1 / HMAC-SHA256 vectors, randomBytes length, randomUUID v4 nibble, and that a
  # setTimeout callback actually fires (its output only appears if the microtask queue drained).
  # Pure JS, zero native execution.
  use ExUnit.Case, async: false

  alias Workbooks.{Compilers, PackageManager}

  @tag :build
  @tag timeout: 300_000
  test "crypto hashes + timers behave through compile+run" do
    shim_dir = Path.join(Compilers.default_root(), "js/shims")
    dir = Path.join(System.tmp_dir!(), "npmcrypto-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    Enum.each(~w(crypto timers), fn s ->
      File.cp!(Path.join(shim_dir, "#{s}.js"), Path.join(dir, "#{s}.js"))
    end)

    File.write!(Path.join(dir, "index.js"), ~S"""
    var crypto = require("./crypto");
    require("./timers"); // installs setTimeout as a global

    var out = [];
    out.push("sha256=" + crypto.createHash("sha256").update("abc").digest("hex"));
    out.push("sha1=" + crypto.createHash("sha1").update("abc").digest("hex"));
    out.push("hmac=" + crypto.createHmac("sha256", "key")
      .update("The quick brown fox jumps over the lazy dog").digest("hex"));
    out.push("rb=" + crypto.randomBytes(8).length);
    out.push("uuidv=" + crypto.randomUUID()[14]);

    setTimeout(function () {
      out.push("timer=ok");
      Javy.IO.writeSync(1, new TextEncoder().encode(out.join("|")));
    }, 0);
    """)

    assert {:ok, js} = Compilers.bundle_dir(dir, "index.js")
    src = Path.join(dir, "_bundle.js")
    File.write!(src, js)
    assert {:ok, wasm, _log} = Compilers.js_compile_to_wasm(src)

    expected =
      [
        "sha256=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "sha1=a9993e364706816aba3e25717850c26c9cd0d89d",
        "hmac=f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
        "rb=8",
        "uuidv=4",
        "timer=ok"
      ]
      |> Enum.join("|")

    assert PackageManager.run(wasm, "", []) |> String.trim() == expected
  end
end

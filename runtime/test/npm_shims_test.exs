defmodule Workbooks.NpmShimsTest do
  # wb-spy.T2.1 — pure-JS Node core shims. Each shim is exercised through the REAL path: the shim
  # files are bundled (Compilers.bundle_dir) with an index that requires + uses them, compiled to
  # wasm via the JS lane, and run — asserting observable behavior. No stubs, zero native execution.
  use ExUnit.Case, async: false

  alias Workbooks.{Compilers, PackageManager}

  @shims ~w(events buffer path util querystring string_decoder assert url process)

  @tag :build
  @tag timeout: 300_000
  test "all node core shims load and behave through compile+run" do
    shim_dir = Path.join(Compilers.default_root(), "js/shims")
    dir = Path.join(System.tmp_dir!(), "npmshims-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    # Copy the shim modules into the project root so relative requires (e.g. url → ./querystring) work.
    Enum.each(@shims, fn s ->
      File.cp!(Path.join(shim_dir, "#{s}.js"), Path.join(dir, "#{s}.js"))
    end)

    File.write!(Path.join(dir, "index.js"), ~S"""
    var EventEmitter = require("./events");
    var Buffer = require("./buffer").Buffer;
    var path = require("./path");
    var util = require("./util");
    var qs = require("./querystring");
    var SD = require("./string_decoder").StringDecoder;
    var assert = require("./assert");
    var url = require("./url");
    var process = require("./process");

    var out = [];

    var ee = new EventEmitter(); var got = 0;
    ee.on("x", function (v) { got = v; }); ee.emit("x", 42);
    out.push("ee=" + got);

    out.push("hex=" + Buffer.from("hi").toString("hex"));
    out.push("b64=" + Buffer.from("Man").toString("base64"));
    out.push("b64rt=" + Buffer.from(Buffer.from("hello").toString("base64"), "base64").toString());

    out.push("join=" + path.join("/a", "b", "../c"));
    out.push("ext=" + path.extname("foo.tar.gz"));

    out.push("fmt=" + util.format("%s-%d", "x", 5));

    out.push("qs=" + qs.stringify({ a: 1, b: 2 }));

    var sd = new SD("utf8");
    out.push("sd=" + sd.write(new Uint8Array([0xc3])) + sd.write(new Uint8Array([0xa9])));

    var threw = false; try { assert.strictEqual(1, 2); } catch (e) { threw = true; }
    assert.strictEqual(1, 1);
    out.push("assert=" + threw);

    var u = url.parse("http://h:8/p?x=1");
    out.push("host=" + u.hostname + ":" + u.port);

    out.push("plat=" + process.platform);

    Javy.IO.writeSync(1, new TextEncoder().encode(out.join("|")));
    """)

    assert {:ok, js} = Compilers.bundle_dir(dir, "index.js")
    src = Path.join(dir, "_bundle.js")
    File.write!(src, js)
    assert {:ok, wasm, _log} = Compilers.js_compile_to_wasm(src)

    expected =
      [
        "ee=42",
        "hex=6869",
        "b64=TWFu",
        "b64rt=hello",
        "join=/a/c",
        "ext=.gz",
        "fmt=x-5",
        "qs=a=1&b=2",
        "sd=é",
        "assert=true",
        "host=h:8",
        "plat=wasm"
      ]
      |> Enum.join("|")

    assert PackageManager.run(wasm, "", []) |> String.trim() == expected
  end
end

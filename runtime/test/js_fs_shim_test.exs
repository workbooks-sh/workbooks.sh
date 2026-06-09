defmodule Workbooks.JsFsShimTest do
  # wb-e1x.3 / JD.3 — the fs shim backed by Javy.VFS, proven through the REAL :dock path:
  # the fs shim is bundled, compiled with the dock harness, and run under Workbooks.JsDock so
  # host_vfs_read/write back it. Exercises write/read/exists/stat/append. Zero native execution.
  # (Bundler NATIVE→SHIM move for fs + closing wb-l52 land in JD.5 with lane routing.)
  use ExUnit.Case, async: false

  alias Workbooks.{Compilers, JsDock}

  @tag :build
  @tag timeout: 300_000
  test "fs read/write/exists/stat/append roundtrip over the VFS via JsDock" do
    shim_dir = Path.join(Compilers.default_root(), "js/shims")
    dir = Path.join(System.tmp_dir!(), "jsfs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    File.cp!(Path.join(shim_dir, "fs.js"), Path.join(dir, "fs.js"))

    File.write!(Path.join(dir, "index.js"), ~S"""
    var fs = require("./fs");
    var out = [];
    out.push("exists0=" + fs.existsSync("/data.txt"));
    fs.writeFileSync("/data.txt", "hello");
    out.push("exists1=" + fs.existsSync("/data.txt"));
    out.push("read=" + fs.readFileSync("/data.txt", "utf8"));
    out.push("size=" + fs.statSync("/data.txt").size);
    fs.appendFileSync("/data.txt", " world");
    out.push("appended=" + fs.readFileSync("/data.txt", "utf8"));
    var bytes = fs.readFileSync("/data.txt");
    out.push("isU8=" + (bytes instanceof Uint8Array));
    Javy.IO.writeSync(1, new TextEncoder().encode(out.join("|")));
    """)

    assert {:ok, js} = Compilers.bundle_dir(dir, "index.js")
    src = Path.join(dir, "_bundle.js")
    File.write!(src, js)
    # :dock lane — env.host_vfs_* imports backed by JsDock
    assert {:ok, wasm, _log} = Compilers.js_compile_to_wasm(src, dock: true)
    assert {:ok, out} = JsDock.run(wasm, "", profile: :minimal)

    assert String.trim(to_string(out)) ==
             "exists0=false|exists1=true|read=hello|size=5|appended=hello world|isU8=true"
  end
end

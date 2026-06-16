defmodule Workbooks.BuildRecipesTest do
  @moduledoc """
  P5 — per-language build recipes + content-addressed command artifacts + --help
  capture. Proves the real vertical, no stubs:
    - PackageManager.build_dir/2 builds a runnable Go (TinyGo wasip1) and JS (Javy)
      command from a real fixture dir; argv + stdin -> stdout works.
    - PackageManager.content_address/1 hashes the bytes into build/commands/<sha>.wasm
      and is idempotent (same source -> same path).
    - CommandRegistry.register_artifact/3 content-addresses on register.
    - PackageManager.capture_help/1 runs a built CLI with ["--help"] (huniq/sd,
      @tag :build — needs the rust wasm toolchain + network for cargo install).
  """
  use ExUnit.Case, async: false
  @moduletag :build

  alias Workbooks.{PackageManager, CommandRegistry}

  @gocli Path.expand("fixtures/gocli", __DIR__)
  @jscli Path.expand("fixtures/jscli", __DIR__)
  @ccli Path.expand("fixtures/ccli", __DIR__)

  test "build_dir Go fixture -> runnable wasip1 command (argv + stdin)" do
    assert {:ok, wasm, :built_dir} = PackageManager.build_dir(@gocli, "go")
    assert File.exists?(wasm)
    out = PackageManager.run(wasm, "alpha\nbeta\n", ["::"])
    assert out =~ ":: alpha"
    assert out =~ ":: beta"
  end

  test "build_dir JS fixture -> runnable command (stdin -> stdout)" do
    assert {:ok, wasm, :built} = PackageManager.build_dir(@jscli, "js")
    assert File.exists?(wasm)
    out = PackageManager.run(wasm, "abc\nXY\n", []) |> String.trim()
    assert out == "cba\nYX"
  end

  test "content_address is idempotent and lands in build/commands" do
    {:ok, wasm, :built_dir} = PackageManager.build_dir(@gocli, "go")
    assert {:ok, a1, sha1} = PackageManager.content_address(wasm)
    assert {:ok, a2, sha2} = PackageManager.content_address(wasm)
    assert sha1 == sha2
    assert a1 == a2
    assert a1 =~ "/build/commands/"
    assert Path.basename(a1) == "#{sha1}.wasm"
  end

  test "register_artifact content-addresses then registers a runnable command" do
    {:ok, wasm, :built_dir} = PackageManager.build_dir(@gocli, "go")
    assert {:ok, addressed} = CommandRegistry.register_artifact("p5-gocli", wasm, :argv)
    assert addressed =~ "/build/commands/"
    assert "p5-gocli" in CommandRegistry.list()
    assert {:ok, out} = CommandRegistry.run("p5-gocli", "one\ntwo\n", ["#"])
    assert out =~ "# one"
  end

  # P10 — mmap emulation shim wired into the C/wasi build path. A C CLI that
  # mmap()s a file MAP_SHARED, reads through the pointer, mutates it, and relies on
  # msync/munmap to flush back. wasi-libc has no working mmap (returns ENOSYS);
  # build/shims/mmap_shim.c emulates it over pread/pwrite, linked via wasm-ld
  # --wrap. Proven end-to-end: read-through AND write-back round-trip.
  test "build_dir C fixture: mmap shim round-trips a file (read + MAP_SHARED write-back)" do
    assert {:ok, wasm, :built} = PackageManager.build_dir(@ccli, "c")
    assert File.exists?(wasm)

    work = Path.join(System.tmp_dir!(), "mmap-rt-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(work)
    File.write!(Path.join(work, "data.txt"), "hello world\n")

    out = PackageManager.run(wasm, "", ["/data.txt"], ["#{work}::/"])
    # read-through-mmap: the guest saw the first byte via pread into the mapping.
    assert out =~ "read-through: h"
    assert out =~ "ok"
    # write-back-through-mmap: mutations flushed to the host file on msync/munmap.
    assert File.read!(Path.join(work, "data.txt")) == "HELLO WORLD\n"
  end

  test "build_dir C: without a preopen the guest cannot reach the host file (isolation)" do
    {:ok, wasm, :built} = PackageManager.build_dir(@ccli, "c")
    # no `dirs` -> no host path mapped into the guest -> open() fails, not a crash.
    out = PackageManager.run(wasm, "", ["/nope.txt"], [])
    refute out =~ "read-through:"
  end

  # wb-fm0.1 — INLINE C (a literate `c` source block, the build_inline path) compiles
  # ENTIRELY in the sandbox via clang.wasm (Compilers.compile_c), zero native execution.
  # This is the inline counterpart to the build_dir C tests above; together they prove
  # both PackageManager C entry points route through the in-sandbox compiler.
  @tag :build
  @tag timeout: 300_000
  test "inline C source compiles in-sandbox (no native toolchain) and runs" do
    src = "#include <stdio.h>\nint main(){ long f=1; for(int i=1;i<=6;i++) f*=i; printf(\"6!=%ld\\n\", f); return 0; }"
    {_name, "c", result} = PackageManager.build(%{"name" => "fac", "lang" => "c", "src" => src})
    assert {:ok, wasm, status} = result
    assert status in [:built, :cached]
    assert File.exists?(wasm)
    assert PackageManager.run(wasm, "", []) |> String.trim() =~ "6!=720"
  end

  # wb-fm0.5 — INLINE Go runs ENTIRELY in the sandbox via the yaegi interpreter (yaegi-run.wasm,
  # built once by native Go cross-compile); the source is embedded as a wbgosrc custom section
  # and extracted at run. Zero native execution of user code, no TinyGo. Self-heals yaegi if absent.
  @tag :build
  @tag timeout: 300_000
  test "inline Go runs in-sandbox via yaegi (no native tinygo)" do
    src = """
    package main
    import ("bufio";"fmt";"os";"strings")
    func main(){
      sc := bufio.NewScanner(os.Stdin)
      for sc.Scan() { fmt.Println(strings.ToUpper(sc.Text())) }
    }
    """

    {_n, "go", {:ok, wasm, status}} = PackageManager.build(%{"name" => "gor", "lang" => "go", "src" => src})
    assert status in [:built, :cached]
    assert PackageManager.run(wasm, "hello\nworld\n", []) |> String.trim() == "HELLO\nWORLD"
  end

  # wb-fm0.6 — INLINE TypeScript compiles to a runnable wasm ENTIRELY in the sandbox: the real
  # tsc (typescript.js) runs inside QuickJS (qjs-run.wasm) to strip types → JS, then the JS lane
  # → wasm. Zero native execution (no bun/esbuild). Self-heals the toolchain if absent.
  @tag :build
  @tag timeout: 300_000
  test "inline TypeScript compiles in-sandbox (real tsc in QuickJS, no native bun) and runs" do
    src = ~S"""
    interface Pt { x: number; y: number }
    const dist = (a: Pt, b: Pt): number => Math.abs(a.x - b.x) + Math.abs(a.y - b.y);
    const out: string = `ts-sandbox dist=${dist({x:0,y:0}, {x:3,y:4})}\n`;
    Javy.IO.writeSync(1, new TextEncoder().encode(out));
    """

    {_n, "ts", {:ok, wasm, status}} = PackageManager.build(%{"name" => "tsr", "lang" => "ts", "src" => src})
    assert status in [:built, :cached]
    assert PackageManager.run(wasm, "", []) |> String.trim() == "ts-sandbox dist=7"
  end

  # wb-fm0.4 — INLINE JS compiles to a runnable wasm ENTIRELY in the sandbox via QuickJS-ng
  # built by clang.wasm (no native javy). The Javy.IO + TextEncoder/Decoder contract is
  # preserved, so existing JS workbooks run unchanged. Self-heals the toolchain if absent.
  @tag :build
  @tag timeout: 300_000
  test "inline JS compiles in-sandbox via QuickJS (no native javy) and runs the Javy.IO contract" do
    src = ~S"""
    const buf = new Uint8Array(65536);
    let total = 0, n;
    while ((n = Javy.IO.readSync(0, buf.subarray(total))) > 0) total += n;
    const text = new TextDecoder().decode(buf.subarray(0, total)).replace(/\n$/, "");
    const out = text.split("\n").map((l) => l.split("").reverse().join("")).join("\n") + "\n";
    Javy.IO.writeSync(1, new TextEncoder().encode(out));
    """

    {_n, "js", {:ok, wasm, status}} = PackageManager.build(%{"name" => "jsr", "lang" => "js", "src" => src})
    assert status in [:built, :cached]
    assert File.exists?(wasm)
    assert PackageManager.run(wasm, "abc\nXY\n", []) |> String.trim() == "cba\nYX"
  end

  # wb-fm0.3 — INLINE Rust with FULL STD (Vec/iterators/println!) compiles to a runnable wasm
  # entirely in the sandbox via mrustc.wasm (.rs→C) → clang.wasm (C→wasm), linked against the
  # libstd that mrustc.wasm prebuilt — zero native execution (no cargo). Requires the one-time
  # libstd prebuild (compilers/rust/provision-rust.sh); skipped with a clear message if absent.
  @tag :build
  @tag timeout: 900_000
  test "inline Rust + full std compiles in-sandbox (no native cargo) and runs" do
    src = """
    fn main() {
        let v: Vec<u32> = (1..=10).collect();
        println!("rust-pm-std={}", v.iter().sum::<u32>());
    }
    """

    case PackageManager.build(%{"name" => "rstd", "lang" => "rust", "src" => src}) do
      {_n, "rust", {:ok, wasm, status}} ->
        assert status in [:built, :cached]
        assert File.exists?(wasm)
        assert PackageManager.run(wasm, "", []) |> String.trim() =~ "rust-pm-std=55"

      {_n, "rust", {:error, {:libstd_not_prebuilt, _}}} ->
        # CI without the prebuilt libstd: run compilers/rust/provision-rust.sh to enable.
        IO.puts("\n[skip] Rust libstd not prebuilt — run compilers/rust/provision-rust.sh")
    end
  end

  # wb-3s8 — Rust with a real crates.io DEPENDENCY, compiled + run ENTIRELY in the sandbox.
  # A component declares deps=["fnv@1.0.7"]; the crate is fetched from static.crates.io, compiled
  # (with its default features) via mrustc.wasm→clang.wasm, and linked. Needs network for fetch.
  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "Rust with a crates.io dependency (fnv) builds + runs in-sandbox" do
    src = """
    use fnv::FnvHashMap;
    fn main() {
        let mut m: FnvHashMap<&str, i32> = FnvHashMap::default();
        for w in "a b a c a b".split_whitespace() { *m.entry(w).or_insert(0) += 1; }
        println!("dep-fnv a={} b={} c={}", m["a"], m["b"], m["c"]);
    }
    """

    case PackageManager.build(%{"name" => "rdep", "lang" => "rust", "src" => src, "deps" => ["fnv@1.0.7"]}) do
      {_n, "rust", {:ok, wasm, st}} ->
        assert st in [:built, :cached]
        assert PackageManager.run(wasm, "", []) |> String.trim() == "dep-fnv a=3 b=2 c=1"

      {_n, "rust", {:error, {:fetch_failed, _, _, _}}} ->
        IO.puts("\n[skip] crates.io fetch failed (offline?) — Rust dep test needs network")
    end
  end

  # wb-fm0.2 — INLINE Zig compiles to a runnable wasm ARTIFACT entirely in the sandbox
  # (zig1.wasm: .zig → C, then clang.wasm: C → wasm), zero native execution. Proves the
  # PackageManager zig lane routes through Workbooks.Compilers, not a native zig.
  @tag :build
  @tag timeout: 600_000
  test "inline Zig source compiles in-sandbox (no native toolchain) and runs" do
    src = ~s|const std = @import("std");\npub fn main() void { std.debug.print("zig-pm={d}\\n", .{6 * 7}); }\n|
    {_name, "zig", result} = PackageManager.build(%{"name" => "zpm", "lang" => "zig", "src" => src})
    assert {:ok, wasm, status} = result
    assert status in [:built, :cached]
    assert File.exists?(wasm)
    assert PackageManager.run(wasm, "", []) |> String.trim() =~ "zig-pm=42"
  end

  @tag :build
  @tag timeout: 420_000
  test "capture_help on huniq: build -> content-address -> --help" do
    assert {:ok, path} = CommandRegistry.build_and_register_crate("huniq", "huniq", :argv)
    assert path =~ "/build/commands/"
    help = PackageManager.capture_help(path)
    assert help =~ "Remove duplicates"
    assert help =~ "USAGE"
  end

  @tag :build
  @tag timeout: 420_000
  test "capture_help on sd: build -> content-address -> --help" do
    assert {:ok, path} = CommandRegistry.build_and_register_crate("sd", "sd", :argv)
    assert path =~ "/build/commands/"
    help = PackageManager.capture_help(path)
    assert help =~ "find & replace"
    assert help =~ "Usage"
  end
end

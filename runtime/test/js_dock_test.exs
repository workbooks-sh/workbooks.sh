defmodule Workbooks.JsDockTest do
  # wb-e1x.2 / JD.2 — the JsDock runner: a :dock-compiled JS command runs under Wasmex with
  # Policy-gated host imports. Proves VFS read/write roundtrip, stdin→stdout, and cap gating
  # (net denied on a non-net profile → Javy.Net.get returns null). Untrusted JS in QuickJS-under-
  # wasmtime; host owns I/O. Zero native execution.
  use ExUnit.Case, async: false

  alias Workbooks.{Compilers, JsDock}

  defp dock_wasm(src) do
    f = Path.join(System.tmp_dir!(), "jsdock-#{System.unique_integer([:positive])}.js")
    File.write!(f, src)
    on_exit(fn -> File.rm(f) end)
    {:ok, wasm, _log} = Compilers.js_compile_to_wasm(f, dock: true)
    wasm
  end

  @tag :build
  @tag timeout: 300_000
  test "VFS write/read roundtrip through host_vfs_* (minimal profile has vfs)" do
    wasm =
      dock_wasm(~S"""
      Javy.VFS.write("/k", "hello-vfs");
      var r = Javy.VFS.read("/k");
      Javy.IO.writeSync(1, new TextEncoder().encode(String(r)));
      """)

    assert {:ok, out} = JsDock.run(wasm, "", profile: :minimal)
    assert String.trim(to_string(out)) == "hello-vfs"
  end

  @tag :build
  @tag timeout: 300_000
  test "stdin is piped to the command and stdout returned" do
    wasm =
      dock_wasm(~S"""
      var buf = new Uint8Array(1 << 16), total = 0, n;
      while ((n = Javy.IO.readSync(0, buf.subarray(total))) > 0) total += n;
      Javy.IO.writeSync(1, buf.subarray(0, total));
      """)

    assert {:ok, out} = JsDock.run(wasm, "ping-pong", profile: :minimal)
    assert String.trim(to_string(out)) == "ping-pong"
  end

  @tag :build
  @tag timeout: 300_000
  test "net is denied on a non-net profile — Javy.Net.get returns null (host fn returns -1)" do
    wasm =
      dock_wasm(~S"""
      var x = Javy.Net.get("http://example.com");
      Javy.IO.writeSync(1, new TextEncoder().encode(x === null ? "denied" : "got"));
      """)

    assert {:ok, out} = JsDock.run(wasm, "", profile: :minimal)
    assert String.trim(to_string(out)) == "denied"
  end

  @tag :netdeps
  @tag :build
  @tag timeout: 300_000
  test "net allowed on a network profile — Javy.Net.get fetches (host-brokered)" do
    wasm =
      dock_wasm(~S"""
      var x = Javy.Net.get("https://registry.npmjs.org/ms");
      Javy.IO.writeSync(1, new TextEncoder().encode(x && x.indexOf("\"name\"") >= 0 ? "fetched" : "empty"));
      """)

    case JsDock.run(wasm, "", profile: :network) do
      {:ok, out} ->
        assert String.trim(to_string(out)) == "fetched"

      {:error, reason} ->
        IO.puts("\n[skip] jsdock net: #{inspect(reason) |> String.slice(0, 120)}")
    end
  end
end

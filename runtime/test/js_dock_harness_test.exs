defmodule Workbooks.JsDockHarnessTest do
  # wb-e1x.1 / JD.1 — the JsDock harness links the env.* host-capability imports into a JS command
  # (so JsDock/Wasmex can back them), while the normal JS lane stays import-free for the CLI. Both
  # are built in-sandbox (clang.wasm). Proven by inspecting the emitted wasm's import names.
  use ExUnit.Case, async: false

  alias Workbooks.Compilers

  @src "Javy.IO.writeSync(1, new TextEncoder().encode('ok'));"

  defp compile(opts) do
    f = Path.join(System.tmp_dir!(), "jsdh-#{System.unique_integer([:positive])}.js")
    File.write!(f, @src)
    on_exit(fn -> File.rm(f) end)
    Compilers.js_compile_to_wasm(f, opts)
  end

  @tag :build
  @tag timeout: 300_000
  test "dock-compiled command imports env.host_http_get / host_vfs_read / host_vfs_write" do
    assert {:ok, wasm, _log} = compile(dock: true)
    bytes = File.read!(wasm)
    assert bytes =~ "host_http_get"
    assert bytes =~ "host_vfs_read"
    assert bytes =~ "host_vfs_write"
    # import module name present too
    assert bytes =~ "env"
  end

  @tag :build
  @tag timeout: 300_000
  test "the normal (non-dock) JS lane carries no host_* imports" do
    assert {:ok, wasm, _log} = compile([])
    bytes = File.read!(wasm)
    refute bytes =~ "host_http_get"
    refute bytes =~ "host_vfs_read"
  end
end

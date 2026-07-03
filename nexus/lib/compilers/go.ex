defmodule Nexus.Compilers.Go do
  @moduledoc """
  The Go lane — shells **tinygo** (native, trusted toolchain) to compile a Go guest to a CORE
  `wasm32-wasi` module. The GUEST runs sandboxed on `TinyLasers.Wasm` (route (a), wb-vhq1u); only the
  compiler runs natively, exactly like the rust/c/zig lanes run their wasm toolchains.

  tinygo binds the host bridge with directives (see `test/fixtures/hello_bridge.go`, the ABI reference):
  `//go:wasmimport env host_call` imports the ONE typed host call; `//go:wasmexport <name>` exposes a
  typed entry. `-buildmode=c-shared` keeps it a reactor (no `_start`); `-target=wasip1` is the core ABI.
  """

  @doc "Compile a Go source file to a wasm core module. `{:ok, wasm_path} | {:error, reason}`."
  def compile_to_wasm(source_path, _opts \\ []) do
    out = Path.join(System.tmp_dir!(), "nxgo_#{System.unique_integer([:positive])}.wasm")
    src = Path.expand(source_path)

    case System.cmd(
           "tinygo",
           ["build", "-o", out, "-target=wasip1", "-buildmode=c-shared", "-no-debug", src],
           stderr_to_stdout: true
         ) do
      {_, 0} -> {:ok, out}
      {err, code} -> {:error, {:go_compile_failed, code, String.slice(err, 0, 600)}}
    end
  end
end

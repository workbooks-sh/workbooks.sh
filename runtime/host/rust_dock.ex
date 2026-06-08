defmodule Workbooks.RustDock do
  @moduledoc """
  Dock host-import surface for compiled-Rust CORE modules (wb-49z/wb-1mv). Rust declares
  `extern "C"` fns; compiled via rust_compile_to_wasm(no_exceptions: true, allow_undefined: true)
  so they survive as `(import "env" <fn>)` and the wasm runs under Wasmex WITHOUT the exceptions
  proposal. `imports/1` returns the Wasmex core-module imports map backing those externs with
  POLICY-GATED host fns (the BEAM does the IO wasm can't: clock now, later vfs/http/llm). This is
  the offload lever — runtime caps wasm alone lacks, mediated by the host.
  """

  @doc "env.* imports for a Rust core module. opts: :caps (list), :vfs."
  def imports(_opts \\ []) do
    %{
      "env" => %{
        # host_now() -> i64 : unix epoch milliseconds (a real cap — wasm has no wall clock)
        "host_now" => {:fn, [], [:i64], fn _ctx -> System.os_time(:millisecond) end}
      }
    }
  end
end

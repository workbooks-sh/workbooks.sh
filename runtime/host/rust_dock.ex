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
        "host_now" => {:fn, [], [:i64], fn _ctx -> System.os_time(:millisecond) end},
        # host_log(ptr,len) -> i32 : host READS the string from wasm linear memory + logs it.
        # Proves memory marshalling (caller.memory) — foundation for all string caps (http/vfs/llm).
        "host_log" =>
          {:fn, [:i32, :i32], [:i32],
           fn ctx, ptr, len ->
             s = Wasmex.Memory.read_string(ctx.caller, ctx.memory, ptr, len)
             IO.puts("[RustDock] host_log: #{s}")
             len
           end},
        # host_http_get(url_ptr,url_len, out_ptr,out_cap) -> i32 : network cap. Host reads URL from
        # wasm mem, BEAM HTTP GET (the IO wasm cant do), writes body into out buffer, returns body
        # len (or -1 on error / truncates to out_cap). THE offload lever — egress via BEAM, policy-
        # gated (TODO: gate on caps allow_http; proof-open here).
        "host_http_get" =>
          {:fn, [:i32, :i32, :i32, :i32], [:i32],
           fn ctx, url_ptr, url_len, out_ptr, out_cap ->
             url = Wasmex.Memory.read_string(ctx.caller, ctx.memory, url_ptr, url_len)
             _ = Application.ensure_all_started(:inets)
             _ = Application.ensure_all_started(:ssl)

             case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 10_000}], body_format: :binary) do
               {:ok, {{_, _status, _}, _hdrs, body}} ->
                 n = min(byte_size(body), out_cap)
                 :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, out_ptr, binary_part(body, 0, n))
                 n

               _ ->
                 -1
             end
           end}
      }
    }
  end
end

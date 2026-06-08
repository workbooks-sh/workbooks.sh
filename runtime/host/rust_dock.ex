defmodule Workbooks.RustDock do
  @moduledoc """
  Dock host-import surface for compiled-Rust CORE modules (wb-49z/wb-1mv). Rust declares
  `extern "C"` fns; compiled via rust_compile_to_wasm(no_exceptions: true, allow_undefined: true)
  so they survive as `(import "env" <fn>)` and the wasm runs under Wasmex WITHOUT the exceptions
  proposal. `imports/1` returns the Wasmex core-module imports map backing those externs with
  POLICY-GATED host fns (the BEAM does the IO wasm can't: clock now, later vfs/http/llm). This is
  the offload lever — runtime caps wasm alone lacks, mediated by the host.
  """

  alias Workbooks.Policy

  @doc """
  env.* imports for a Rust core module. opts: :profile (caps gate, default :minimal).
  Ambient caps (host_now, host_log) always present; egress (host_http_get) ONLY when the profile
  permits HTTP (Policy.allow_http? — net/browse). Untrusted Rust on a non-net profile sees no
  http import → the extern is unresolved → wasm-ld --allow-undefined leaves it importable but
  Wasmex instantiation w/o the import fails the call, so DON'T request it from a minimal program.
  """
  def imports(opts \\ []) do
    profile = Keyword.get(opts, :profile, :minimal)
    base = ambient()
    env = if Policy.allow_http?(profile), do: Map.merge(base, egress()), else: base
    %{"env" => env}
  end

  defp ambient do
    %{
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
           end}
    }
  end

  # Egress — ONLY merged when Policy.allow_http? (net/browse profile). Untrusted Rust on a
  # minimal/non-net profile never gets this import → no host-mediated network.
  defp egress do
    %{
      # host_http_get(url_ptr,url_len, out_ptr,out_cap) -> i32 : host reads URL from wasm mem,
      # BEAM HTTP GET (the IO wasm cant do), writes body into out buffer, returns body len
      # (-1 err / truncates to out_cap). The offload lever — egress via BEAM, policy-gated.
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
  end
end

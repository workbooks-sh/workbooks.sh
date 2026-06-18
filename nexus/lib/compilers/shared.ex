defmodule Nexus.Compilers.Shared do
  @moduledoc """
  Cross-cutting helpers shared by every compiler lane (Native/Rust/Js) and the
  `Nexus.Compilers` facade: discovery root, the manifest reader, the wasmtime
  sandbox executor, a verified-TLS HTTPS GET, and shell-escaping. Extracted from the
  former compilers.ex god-file so each lane module depends on ONE home for these.
  """

  # clang/lld (YoWASP LLVM-for-wasi) link paths inside the mounted sysroot (/usr).
  @clang_lib_rt "/usr/lib/wasm32-unknown-wasip1"
  @clang_lib_c "/usr/lib/wasm32-wasip1"

  def clang_lib_rt, do: @clang_lib_rt
  def clang_lib_c, do: @clang_lib_c

  @doc "Discovery root for compilers/<lang>/."
  def default_root do
    Enum.find(["compilers", "../runtime/compilers", "runtime/compilers", Path.expand("../runtime/compilers", File.cwd!())], &File.dir?/1) ||
      "compilers"
  end

  @doc "Run `wasmtime run <args>` and return its combined output (the sandbox executor)."
  def wasmtime(args) do
    {out, _} = System.cmd("wasmtime", ["run"] ++ [] ++ args, stderr_to_stdout: true)
    out
  end

  @doc """
  Pure-Erlang HTTPS GET (:httpc) with VERIFIED TLS via the OS trust store — replaces the curl
  binary in the compile path (wb-ova). Follows redirects (static.crates.io). Returns {:ok, body}.
  """
  def http_get(url) do
    :inets.start()
    :ssl.start()

    ssl_opts = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      depth: 3
    ]

    req = {String.to_charlist(url), []}
    http_opts = [ssl: ssl_opts, timeout: 30_000, connect_timeout: 15_000, autoredirect: true]

    case :httpc.request(:get, req, http_opts, body_format: :binary) do
      {:ok, {{_v, 200, _}, _headers, body}} -> {:ok, body}
      {:ok, {{_v, code, _}, _headers, _body}} -> {:error, {:http_status, code}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Single-quote escape a path for a `sh -c` command line."
  def esc(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"
end

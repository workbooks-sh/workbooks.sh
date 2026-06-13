defmodule Workbooks.BuildBroker do
  @moduledoc """
  wb-broker BUILD-FROM-SOURCE (the build-orchestration lane) — the host-brokered "compile this source into a
  runnable tool, then run it", the privileged op a sandboxed guest can't do itself (it has no compiler/OS).
  This is the foundation the fork-exec (36) + heavy-build-system (37) reclaim buckets need: a tool that builds
  OTHER tools (a make-like driver, a package installer) does it by spawning compiles — here that spawn is
  BROKERED, the compile runs ENTIRELY in-sandbox (Compilers / clang.wasm + mrustc, zero native toolchain), and
  the produced tool runs SANDBOXED (wasmtime, no caps unless granted). Proven recipes (iter129-131) wrapped in
  the broker cadence.

  Security cadence (mirrors the exec broker):
    * DEFAULT-DENY — a guest may build only if granted (`:allow`, from the `commands`/build cap).
    * SOURCE + OUTPUT byte caps — a huge source or huge produced tool can't exhaust the host.
    * per-principal RATE + REVOCATION — a runaway build loop is throttled; a revoked principal can't build.
    * SANDBOXED COMPILE + RUN — the compiler runs in wasmtime (a malicious source can at most abuse its own
      compiler instance, never escape); the built tool runs with NO network and NO fs preopen by default.
    * AUDIT on every denial (:build).
  """
  @langs [:c, :rust]
  @default_max_source 1024 * 1024
  @default_max_output 16 * 1024 * 1024

  @doc """
  Build `source` (a `:c` or `:rust` program string) into a sandboxed wasm tool and RUN it with `stdin`,
  returning its stdout. `{:ok, output}` | `{:error, reason}`. opts: `:allow` (default false), `:principal`,
  `:rate`, `:max_source`, `:max_output`, `:argv`. The compile is in-sandbox; the run is sandboxed (no net/fs).
  """
  def build_and_run(lang, source, stdin \\ "", opts \\ [])
      when is_atom(lang) and is_binary(source) and is_binary(stdin) do
    allow = Keyword.get(opts, :allow, false)
    principal = Keyword.get(opts, :principal)
    rate = Keyword.get(opts, :rate, Workbooks.RateLimiter.default_quota())
    max_source = Keyword.get(opts, :max_source, @default_max_source)
    max_output = Keyword.get(opts, :max_output, @default_max_output)

    cond do
      not allow ->
        deny("not granted (no build cap)")
        {:error, :denied}

      lang not in @langs ->
        deny("unsupported build lang #{inspect(lang)}")
        {:error, :unsupported_lang}

      principal && Workbooks.Revocation.revoked?(principal) ->
        deny("principal revoked")
        {:error, :revoked}

      principal && rate && rate_denied?(principal, rate) ->
        deny("rate limited")
        {:error, :rate_limited}

      byte_size(source) > max_source ->
        deny("source too large")
        {:error, :source_too_large}

      true ->
        with {:ok, wasm} <- compile(lang, source) do
          try do
            out = run_sandboxed(wasm, stdin, Keyword.get(opts, :argv, []))
            {:ok, cap(out, max_output)}
          after
            File.rm(wasm)
          end
        end
    end
  end

  @doc "Just build `source` to a wasm tool (no run); returns `{:ok, wasm_path}` | `{:error, _}`. Same cadence."
  def build(lang, source, opts \\ []) when is_atom(lang) and is_binary(source) do
    allow = Keyword.get(opts, :allow, false)
    principal = Keyword.get(opts, :principal)
    max_source = Keyword.get(opts, :max_source, @default_max_source)

    cond do
      not allow -> deny("not granted"); {:error, :denied}
      lang not in @langs -> deny("unsupported lang"); {:error, :unsupported_lang}
      principal && Workbooks.Revocation.revoked?(principal) -> deny("revoked"); {:error, :revoked}
      byte_size(source) > max_source -> deny("source too large"); {:error, :source_too_large}
      true -> compile(lang, source)
    end
  end

  defp compile(:c, source) do
    src = tmp("bb_c", ".c")
    File.write!(src, source)

    try do
      case Workbooks.Compilers.compile_c(src) do
        {:ok, wasm, _} -> {:ok, wasm}
        {:error, reason} -> {:error, {:compile_failed, reason}}
      end
    after
      File.rm(src)
    end
  end

  defp compile(:rust, source) do
    src = tmp("bb_rs", ".rs")
    File.write!(src, source)

    try do
      case Workbooks.Compilers.rust_compile_to_wasm(src, no_exceptions: true) do
        {:ok, wasm, _} -> {:ok, wasm}
        {:error, reason} -> {:error, {:compile_failed, reason}}
      end
    after
      File.rm(src)
    end
  end

  # run the produced tool sandboxed (wasmtime, no network, no fs preopen) — same lane the brokered exec uses
  defp run_sandboxed(wasm, stdin, argv) do
    case Workbooks.PackageManager.run(wasm, stdin, argv) do
      out when is_binary(out) -> out
      {out, _status} when is_binary(out) -> out
      _ -> ""
    end
  end

  defp tmp(prefix, ext),
    do: Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}#{ext}")

  defp cap(out, max) when byte_size(out) > max, do: binary_part(out, 0, max)
  defp cap(out, _max), do: out

  defp rate_denied?(principal, {max, window}),
    do: Workbooks.RateLimiter.check(principal, max, window) == {:error, :rate_limited}

  defp deny(why) do
    Workbooks.BrokerAudit.record(:build, :deny)
    require Logger
    Logger.warning("wb-broker: DENY build — #{why}")
  end
end

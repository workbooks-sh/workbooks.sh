defmodule Nexus.Wasm.Aot do
  @moduledoc """
  Ahead-of-time compilation cache for the wasmtime CLI lane.

  Every `wasmtime run <module.wasm>` cold-JIT-compiles the module before executing it — for the
  render/kit modules that is ~0.7s and ~120MB of Cranelift working set *per call*, dwarfing the
  actual work. This caches the compiled artifact: `wasmtime compile` once → a `.cwasm` on disk →
  every later run loads it with `--allow-precompiled` (mmap, no recompile). Measured on
  `render_text.wasm`: 1.7x faster, 2.6x less RSS, byte-identical output.

  ## Isolation

  A `.cwasm` is read-only machine code with **no tenant state** — sharing it across runs is exactly
  the OS sharing a library's text segment. Each `wasmtime run` still gets its own store + linear
  memory, so multi-tenant isolation is untouched.

  ## Version safety

  A precompiled artifact is only loadable by the wasmtime version that produced it (the format
  embeds a version check and refuses mismatches). The cache key includes the wasmtime version and
  the source mtime, so a toolchain or module change transparently recompiles. Any failure falls
  back to plain JIT — precompilation is an optimization, never a correctness dependency.
  """

  @doc """
  Resolve a `.wasm` to the args wasmtime should run. Returns `{flags, exec_path}`:

    * `{["--allow-precompiled"], "/…/mod.cwasm"}` when a precompiled artifact is ready
    * `{[], "/…/mod.wasm"}` when it isn't (JIT fallback — always correct, just slower)

  Call sites splice it as `["wasmtime", "run"] ++ flags ++ ["--dir", mount, exec | argv]`.
  """
  @spec resolve(Path.t()) :: {[String.t()], Path.t()}
  def resolve(wasm) do
    case ensure(wasm) do
      {:precompiled, cwasm} -> {["--allow-precompiled"], cwasm}
      {:jit, path} -> {[], path}
    end
  end

  @doc """
  Precompile the first real `*.wasm` module in an arg list (its position among flags is arbitrary):
  swaps it for the `.cwasm` and prepends `--allow-precompiled`. Returns the args unchanged when no
  module arg resolves. For the compiler lane (`wasmtime run --dir … clang.wasm …`) where the module
  isn't the first token.
  """
  @spec resolve_args([String.t()]) :: [String.t()]
  def resolve_args(args) do
    case Enum.find_index(args, &module_arg?/1) do
      nil ->
        args

      i ->
        case ensure(Enum.at(args, i)) do
          {:precompiled, cwasm} -> ["--allow-precompiled" | List.replace_at(args, i, cwasm)]
          {:jit, _} -> args
        end
    end
  end

  defp module_arg?(a) when is_binary(a), do: String.ends_with?(a, ".wasm") and File.exists?(a)
  defp module_arg?(_), do: false

  @doc "Like `resolve/1` but returns the tagged result. Memoized per (module, mtime, wasmtime version)."
  @spec ensure(Path.t()) :: {:precompiled, Path.t()} | {:jit, Path.t()}
  def ensure(wasm) do
    case key(wasm) do
      nil ->
        {:jit, wasm}

      k ->
        case :persistent_term.get({__MODULE__, k}, :miss) do
          :miss ->
            result = compile_or_jit(wasm, k)
            :persistent_term.put({__MODULE__, k}, result)
            result

          cached ->
            cached
        end
    end
  end

  # cache key = basename + source mtime + wasmtime version; nil if the module is missing.
  defp key(wasm) do
    case File.stat(wasm, time: :posix) do
      {:ok, %{mtime: mtime}} -> "#{Path.basename(wasm, ".wasm")}-#{mtime}-#{wt_version()}"
      _ -> nil
    end
  end

  defp compile_or_jit(wasm, k) do
    cwasm = Path.join(cache_dir(), k <> ".cwasm")

    cond do
      File.exists?(cwasm) ->
        {:precompiled, cwasm}

      true ->
        case compile(wasm, cwasm) do
          :ok -> {:precompiled, cwasm}
          :error -> {:jit, wasm}
        end
    end
  end

  # Compile to a unique temp, then atomically rename into place — concurrent cold callers may each
  # compile (idempotent, ~once ever per module/version); the last rename wins, both artifacts equal.
  defp compile(wasm, cwasm) do
    File.mkdir_p!(cache_dir())
    tmp = cwasm <> ".#{System.unique_integer([:positive])}.tmp"

    try do
      case System.cmd("wasmtime", ["compile", wasm, "-o", tmp], stderr_to_stdout: true) do
        {_, 0} ->
          File.rename(tmp, cwasm)
          :ok

        {_out, _code} ->
          :error
      end
    rescue
      _ -> :error
    after
      File.rm(tmp)
    end
  end

  defp cache_dir,
    do: Application.get_env(:nexus, :cwasm_dir, Path.join(System.tmp_dir!(), "nexus-cwasm"))

  # wasmtime CLI version, memoized — part of the cache key so a toolchain bump recompiles.
  defp wt_version do
    case :persistent_term.get({__MODULE__, :wt_version}, nil) do
      nil ->
        v =
          case System.cmd("wasmtime", ["--version"], stderr_to_stdout: true) do
            {out, 0} -> out |> String.trim() |> String.replace(~r/\s+/, "_")
            _ -> "unknown"
          end

        :persistent_term.put({__MODULE__, :wt_version}, v)
        v

      v ->
        v
    end
  end
end

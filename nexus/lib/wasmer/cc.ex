defmodule Nexus.Wasmer.Cc do
  @moduledoc """
  The C → **Wasmer-runnable wasm** toolkit compile lane (Phase 3). Authored toolkits used to target the
  old wasmtime `wasm32-wasi` kit format; this compiles them to a WASIX/EH module Wasmer runs, so a custom
  toolkit composes in the agent's bash pipes (`cat x | mytoolkit`) just like coreutils.

  Two steps, the recipe decoded in the wasix spike ([[wasix-shell-migration]]):

    1. **clang** (brew LLVM, real wasm backend) `--target=wasm32-wasip1` against the **wasix-libc EH
       sysroot**, with the exception-handling + thread/atomics flags + emulated-syscall libs.
    2. **wasm-opt `--translate-to-exnref`** (cargo-wasix's wasm-opt) — WASIX uses exception-handling →
       exnref for its fork/setjmp/stack mechanism; this is the keystone that makes the module actually
       run on Wasmer (plain clang output traps).

  Paths resolve from config (`config :nexus, Nexus.Wasmer.Cc, clang:/sysroot:/resource_dir:/wasm_opt:`)
  → known image paths → the local spike defaults, so dev works out of the box and the image overrides.
  `available?/0` gates callers (toolkit compile falls back / errors clearly when the toolchain is absent,
  exactly like the other compiler lanes).
  """

  @doc "Whether the EH toolchain (clang + wasix sysroot + wasm-opt) is present."
  def available? do
    clang() != nil and sysroot() != nil and wasm_opt() != nil
  end

  @doc """
  Compile C `source` to a Wasmer-runnable wasm CLI. Returns `{:ok, wasm_path}` (a temp file) or
  `{:error, reason}`. No-fork filters (stdin→stdout, the common toolkit shape) run cleanly; a forking
  program needs the full EH snapshot path (tracked upstream).
  """
  def compile(source) when is_binary(source) do
    if available?() do
      tmp = Path.join(System.tmp_dir!(), "wbcc_#{System.unique_integer([:positive])}")
      src = tmp <> ".c"
      raw = tmp <> ".raw.wasm"
      out = tmp <> ".wasm"
      File.write!(src, source)

      with {:ok, _} <- run_clang(src, raw),
           {:ok, _} <- run_wasm_opt(raw, out) do
        File.rm(src)
        File.rm(raw)
        {:ok, out}
      else
        {:error, _} = e ->
          Enum.each([src, raw], &File.rm/1)
          e
      end
    else
      {:error, :wasix_toolchain_absent}
    end
  end

  defp run_clang(src, out) do
    args =
      ["--target=wasm32-wasip1", "--sysroot=#{sysroot()}"] ++
        resource_dir_flag() ++
        ~w(-D_GNU_SOURCE -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID -D_WASI_EMULATED_MMAN) ++
        ~w(-matomics -mbulk-memory -mmutable-globals -mexception-handling -pthread) ++
        ~w(-Wno-implicit-function-declaration -Wno-int-conversion) ++
        [src, "-o", out] ++
        ~w(-lwasi-emulated-process-clocks -lwasi-emulated-getpid -lwasi-emulated-mman) ++
        ["-Wl,--shared-memory,--max-memory=4294967296"]

    case System.cmd(clang(), args, stderr_to_stdout: true) do
      {_, 0} -> {:ok, out}
      {log, code} -> {:error, {:c_compile_failed, code, String.slice(log, 0, 800)}}
    end
  end

  # The keystone: translate EH → exnref so Wasmer runs it (plain clang output traps at runtime).
  defp run_wasm_opt(in_wasm, out) do
    args =
      [in_wasm, "-O3", "--enable-bulk-memory", "--enable-threads", "--enable-reference-types",
       "--no-validation", "--translate-to-exnref", "--debuginfo", "-o", out]

    case System.cmd(wasm_opt(), args, stderr_to_stdout: true) do
      {_, 0} -> {:ok, out}
      {log, code} -> {:error, {:wasm_opt_failed, code, String.slice(log, 0, 800)}}
    end
  end

  # ── path resolution (config → image → local spike) ───────────────────────────────────────────────

  defp cfg(key), do: Keyword.get(Application.get_env(:nexus, __MODULE__, []), key)

  defp clang, do: first_existing([cfg(:clang), "/opt/wasix/clang", "/opt/homebrew/opt/llvm/bin/clang"])

  defp sysroot,
    do: first_existing([cfg(:sysroot), "/opt/wasix/sysroot", "/tmp/wasix-eh/wasix-sysroot-eh/sysroot"])

  defp wasm_opt do
    cached = Path.wildcard(Path.join(System.user_home() || "/root", "Library/Caches/cargo-wasix/*/wasm-opt/bin/wasm-opt"))
    first_existing([cfg(:wasm_opt), "/opt/wasix/wasm-opt"] ++ cached ++ ["/opt/homebrew/bin/wasm-opt"])
  end

  defp resource_dir_flag do
    case first_existing([cfg(:resource_dir), "/opt/wasix/rd", "/tmp/wasix-eh-rd"]) do
      nil -> []
      rd -> ["-resource-dir=#{rd}"]
    end
  end

  defp first_existing(paths) do
    Enum.find(paths, fn p -> is_binary(p) and File.exists?(p) end)
  end
end

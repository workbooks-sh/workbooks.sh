defmodule Nexus.ProcMacroHost do
  @moduledoc """
  Host side of the proc-macro exec-bridge (wb-v3d / wb-zq4 gap #2).

  `mrustc_pm.wasm` (mrustc built with -DWB_PROCMACRO_HOST) replaces the native posix_spawn of a
  proc-macro executable with two host imports under the `workbooks` module:

    * `pm_expand(exe_ptr,exe_len, name_ptr,name_len, in_ptr,in_len) -> i32`
        Reads the proc-macro server path, the macro name, and the buffered token-protocol input
        from guest memory; runs the SERVER wasm (the proc-macro compiled --crate-type proc-macro,
        which mrustc gives a `fn main(){ proc_macro::main(&MACROS) }` stdin/stdout loop); stashes
        the result and returns its length.
    * `pm_read(out_ptr,out_len)` — copies the stashed result back into guest memory.

  Because the wasmtime CLI can't define custom imports, the proc-macro-expanding compile used to run
  `mrustc_pm.wasm` on the wasmex NIF. wasmex is being deleted (wb-4z3fv) and `run_mrustc/5` is now GATED
  (see its doc): proc-macro expansion is unsupported until `mrustc_pm` is hosted on `TinyLasers.Wasm`
  (its `:tl_imports` seam can provide `pm_expand`/`pm_read`, but the host-FS compile dir must first be
  staged into TL's VFS — deferred to the wasmtime-CLI→TL migration). Non-proc-macro compiles keep using
  the CLI with the plain `mrustc_std.wasm`, unaffected. `run_server`/`run_wasm_bounded` (wasmtime CLI,
  not wasmex) are unchanged — the server runner is ready for when the mrustc_pm host is wired to TL.
  """

  @doc """
  Run `mrustc_pm.wasm` for one compile that may expand proc-macros.

  RETIRED off wasmex (wb-4z3fv — "delete the foreign runtime"). This ran `mrustc_pm.wasm` (a full Rust
  compiler) on the **wasmex** NIF because the `pm_expand`/`pm_read` custom host imports can't be defined
  on the wasmtime CLI. `TinyLasers.Wasm` CAN host those imports (via `:tl_imports` + `read/write_bytes`),
  but mrustc_pm reads its source/dep/libstd files from the **host FS** through the wasmtime-CLI model,
  while TL's WASI is **VFS-backed** — so a faithful port must stage the whole compile dir into TL's VFS
  and run the compiler on TL's interpreter. That belongs with the broader wasmtime-CLI→TL migration (which
  also owns the non-proc-macro mrustc, the proc-macro servers, and the render_* CLI programs — all host-FS
  + CLI). Until then proc-macro EXPANSION is unsupported on the TL path (like python); non-proc-macro rust
  compiles are unaffected (they never call this — `rust.ex` only routes here when `pm_servers != []`).

  Returns `{:error, {:proc_macro_unsupported_on_tl, msg}}` — `rust.ex` logs it and the compile fails
  cleanly (no `.c` emitted) rather than silently falling back to a foreign runtime.
  """
  def run_mrustc(_pm_wasm, _args, _mrdir, _env, _opts \\ []) do
    {:error,
     {:proc_macro_unsupported_on_tl,
      "proc-macro expansion (mrustc_pm) is not available without wasmex — pending the wasmtime-CLI→TinyLasers migration (wb-4z3fv). Non-proc-macro rust compiles are unaffected."}}
  end

  @doc """
  Run a proc-macro SERVER wasm: feed `input` (the token-protocol blob) on stdin, return stdout
  bytes (a leading status byte + the result token stream). `exe` is the server `.wasm` path.
  Uses the wasmtime CLI with stdin redirection — exactly the proven manual round-trip.
  """
  def run_server(exe, name, input, opts \\ []) do
    runner = Keyword.get(opts, :wasmtime, "wasmtime")
    exe = Path.expand(server_wasm_for(exe), Keyword.get(opts, :mrdir, File.cwd!()))
    # SECURITY: the server is UNTRUSTED code (an arbitrary proc-macro / build script). It runs in the
    # wasm sandbox (no ambient FS/net/spawn — it can't escape or exfiltrate), but a malicious/buggy
    # one can spin forever (DoS). Bound wall-clock with a shell watchdog that hard-kills wasmtime on
    # overrun, and cap stack. (Memory/fuel caps land when this moves to the TinyLasers.Wasm bounded run.)
    secs = max(1, div(Keyword.get(opts, :exec_timeout_ms, 60_000), 1000))
    tmp = Path.join(System.tmp_dir!(), "wbpm-#{System.unique_integer([:positive])}.bin")
    File.write!(tmp, input)

    try do
      # stdin redirection via sh -c matches the validated `server.wasm <name> < blob` round-trip.
      mem = Nexus.Config.sandbox_compile_memory_mb() * 1024 * 1024
      run = "#{runner} run -W exceptions=y -W max-wasm-stack=536870912 -W max-memory-size=#{mem} -W trap-on-grow-failure=y #{shq(exe)} #{shq(name)} < #{shq(tmp)}"
      # watchdog: run in bg, kill -9 after `secs`, propagate the real exit code.
      cmd = "#{run} & pid=$!; ( sleep #{secs}; kill -9 $pid 2>/dev/null ) & wd=$!; wait $pid; rc=$?; kill $wd 2>/dev/null; exit $rc"

      # wb-3f42: bound concurrent proc-macro subprocess fan-out (separate :subproc lane, no deadlock
      # with the caller's :compile slot).
      Nexus.Wasm.Gate.with_slot(:subproc, fn ->
        case System.cmd("sh", ["-c", cmd], env: Nexus.Sandbox.subprocess_env(), stderr_to_stdout: false) do
          {output, 0} -> {:ok, output}
          {_output, 137} -> {:error, {:server_timeout, secs}}
          {output, code} -> {:error, {:server_exit, code, String.slice(output, 0, 300)}}
        end
      end)
    after
      File.rm(tmp)
    end
  end

  @doc """
  Run a wasm COMMAND in the sandbox, wall-clock bounded (the watchdog hard-kills wasmtime on
  overrun). Generic bounded-exec for untrusted in-sandbox programs (build scripts, etc.) — one
  place for the time guard. opts: :dirs (["host::guest", …] preopens), :env (["K=V", …]),
  :exec_timeout_ms (default 30s). Returns {stdout, exit_code}; exit 137 = killed by the watchdog.
  """
  def run_wasm_bounded(wasm, argv \\ [], opts \\ []) do
    runner = Keyword.get(opts, :wasmtime, "wasmtime")
    secs = max(1, div(Keyword.get(opts, :exec_timeout_ms, 30_000), 1000))
    dirs = Keyword.get(opts, :dirs, []) |> Enum.flat_map(&["--dir", &1])
    env = Keyword.get(opts, :env, []) |> Enum.flat_map(&["--env", &1])

    mem = Nexus.Config.sandbox_compile_memory_mb() * 1024 * 1024

    parts =
      [runner, "run"] ++
        ["-W", "exceptions=y", "-W", "max-wasm-stack=134217728",
         "-W", "max-memory-size=#{mem}", "-W", "trap-on-grow-failure=y"] ++
        env ++ dirs ++ [wasm] ++ argv

    run = parts |> Enum.map(&shq/1) |> Enum.join(" ")
    cmd = "#{run} & pid=$!; ( sleep #{secs}; kill -9 $pid 2>/dev/null ) & wd=$!; wait $pid; rc=$?; kill $wd 2>/dev/null; exit $rc"

    # wb-3f42: bound build-script subprocess fan-out (separate :subproc lane).
    Nexus.Wasm.Gate.with_slot(:subproc, fn ->
      System.cmd("sh", ["-c", cmd], env: Nexus.Sandbox.subprocess_env(), stderr_to_stdout: false)
    end)
  end

  defp shq(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  # mrustc passes whatever it loaded the proc-macro crate from — for a top-level dep that's the
  # rewritten server path; for a TRANSITIVE proc-macro (e.g. serde_derive pulled by serde) it's the
  # `lib<crate>.rlib` it found on the search path. Map any `…/lib<crate>.rlib` to the sibling
  # `<crate>_server.wasm` the pipeline linked; pass anything else (already a .wasm) through.
  defp server_wasm_for(exe) do
    base = Path.basename(exe)

    if String.ends_with?(base, ".rlib") and String.starts_with?(base, "lib") do
      crate = base |> String.replace_prefix("lib", "") |> String.replace_suffix(".rlib", "") |> String.replace("-", "_")
      Path.join(Path.dirname(exe), "#{crate}_server.wasm")
    else
      exe
    end
  end
end

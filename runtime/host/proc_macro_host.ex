defmodule Workbooks.ProcMacroHost do
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

  Because the wasmtime CLI can't define custom imports, the proc-macro-expanding compile must run
  through here (Wasmex/BEAM) rather than the CLI. Non-proc-macro compiles keep using the CLI with
  the plain `mrustc_std.wasm`.
  """

  alias Wasmex.Wasi.{WasiOptions, PreopenOptions}

  @doc """
  Run `mrustc_pm.wasm` for one compile that may expand proc-macros.

    * `pm_wasm`  — path to mrustc_pm.wasm
    * `args`     — mrustc CLI args (without argv0)
    * `mrdir`    — guest working dir (preopened as ".")
    * `env`      — %{} of env vars (MRUSTC_TARGET_VER etc.)

  Returns {:ok, stdout} | {:error, reason}. The proc-macro servers are run by `wasmtime` on the
  host (the proven path) — `exe` is whatever `--extern <crate>=<path>` gave mrustc, so point it at
  the server `.wasm` (with a sibling `<path>.hir` for the crate metadata).
  """
  def run_mrustc(pm_wasm, args, mrdir, env, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 180_000)
    {:ok, stash} = Agent.start_link(fn -> <<>> end)
    {:ok, out} = Wasmex.Pipe.new()
    {:ok, err} = Wasmex.Pipe.new()

    wasi = %WasiOptions{
      args: ["mrustc" | args],
      env: env,
      stdout: out,
      stderr: err,
      preopen: [
        %PreopenOptions{path: mrdir, alias: "."},
        %PreopenOptions{path: Path.join(mrdir, ".mrtmp"), alias: "/tmp"}
      ]
    }

    # The proc-macro server path mrustc passes is relative to its cwd (the preopened mrdir); the
    # host runs wasmtime from elsewhere, so resolve it against mrdir.
    imports = %{"workbooks" => pm_imports(stash, Keyword.put(opts, :mrdir, mrdir))}

    try do
      with {:ok, pid} <- Wasmex.start_link(%{bytes: File.read!(pm_wasm), wasi: wasi, imports: imports}),
           {:ok, _} <- Wasmex.call_function(pid, "_start", [], timeout) do
        Wasmex.Pipe.seek(out, 0)
        {:ok, Wasmex.Pipe.read(out)}
      else
        {:error, reason} ->
          Wasmex.Pipe.seek(err, 0)
          {:error, {:mrustc_pm_failed, reason, Wasmex.Pipe.read(err)}}
      end
    after
      Agent.stop(stash)
    end
  end

  defp pm_imports(stash, opts) do
    %{
      "pm_expand" =>
        {:fn, [:i32, :i32, :i32, :i32, :i32, :i32], [:i32],
         fn ctx, exe_p, exe_l, name_p, name_l, in_p, in_l ->
           mem = ctx.memory
           cal = ctx.caller
           exe = Wasmex.Memory.read_string(cal, mem, exe_p, exe_l)
           name = Wasmex.Memory.read_string(cal, mem, name_p, name_l)
           input = Wasmex.Memory.read_binary(cal, mem, in_p, in_l)

           if System.get_env("WB_PM_DBG"), do: IO.puts("[ProcMacroHost] pm_expand: exe=#{exe} name=#{name} in_bytes=#{byte_size(input)}")
           case run_server(exe, name, input, opts) do
             {:ok, output} ->
               if System.get_env("WB_PM_DBG"), do: IO.puts("[ProcMacroHost] pm_expand -> #{byte_size(output)} bytes back")
               Agent.update(stash, fn _ -> output end)
               byte_size(output)

             {:error, reason} ->
               IO.warn("[ProcMacroHost] server failed: #{inspect(reason)}")
               -1
           end
         end},
      "pm_read" =>
        {:fn, [:i32, :i32], [],
         fn ctx, out_p, out_l ->
           data = Agent.get(stash, & &1)
           slice = if byte_size(data) >= out_l, do: binary_part(data, 0, out_l), else: data
           Wasmex.Memory.write_binary(ctx.caller, ctx.memory, out_p, slice)
           nil
         end}
    }
  end

  @doc """
  Run a proc-macro SERVER wasm: feed `input` (the token-protocol blob) on stdin, return stdout
  bytes (a leading status byte + the result token stream). `exe` is the server `.wasm` path.
  Uses the wasmtime CLI with stdin redirection — exactly the proven manual round-trip.
  """
  def run_server(exe, name, input, opts \\ []) do
    runner = Keyword.get(opts, :wasmtime, "wasmtime")
    exe = Path.expand(exe, Keyword.get(opts, :mrdir, File.cwd!()))
    tmp = Path.join(System.tmp_dir!(), "wbpm-#{System.unique_integer([:positive])}.bin")
    File.write!(tmp, input)

    try do
      # stdin redirection via sh -c matches the validated `server.wasm <name> < blob` round-trip.
      cmd = "#{runner} run -W exceptions=y #{shq(exe)} #{shq(name)} < #{shq(tmp)}"

      case System.cmd("sh", ["-c", cmd], stderr_to_stdout: false) do
        {output, 0} -> {:ok, output}
        {output, code} -> {:error, {:server_exit, code, String.slice(output, 0, 300)}}
      end
    after
      File.rm(tmp)
    end
  end

  defp shq(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"
end

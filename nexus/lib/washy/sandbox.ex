defmodule Nexus.Washy.Sandbox do
  @moduledoc """
  The **bounded run harness** for untrusted wasm — the one entry point production uses to execute a
  guest. It wraps `Nexus.Washy.call_io/4` in a fresh, isolated, time-bounded process so a hostile or
  buggy module cannot harm the host:

    * **wall-clock** — the guest runs in a `Task`; past `:timeout_ms` it is `:brutal_kill`ed → `{:timeout}`.
    * **fuel / call-depth / memory** — bounded by the interpreter itself (atomics counters → traps;
      memory capped at the allocation). Passed through via opts.
    * **process isolation** — the guest runs in its OWN process; a trap or crash stays there, the
      caller (and the VM) survive. This is the BEAM isolation thesis as an API.
    * **output cap** — captured stdout is truncated at `:max_output` bytes (`truncated?: true`).

  Returns one of:
    `{:ok, result, stdout, meta}` · `{:trap, reason}` · `{:exit, code, stdout}` · `{:timeout}` · `{:error, term}`

  Per-run context (VFS backend, argv, stdin) is snapshotted from the caller's process dict and replanted
  into the run process, so existing call sites keep working unchanged.
  """
  alias Nexus.Washy
  alias Nexus.Washy.Trap

  @default_timeout_ms 30_000
  @default_max_output 16 * 1024 * 1024

  # process-dict keys that carry per-run guest context across into the isolated run process
  @ctx_keys [:washy_vfs, :washy_fds, :washy_nextfd, :washy_argv, :washy_stdin, :washy_backend, :washy_clock, :washy_out]

  @doc """
  Run exported `name(args)` of `mod` under all bounds. Opts: `:timeout_ms` (default #{@default_timeout_ms}),
  `:max_output` (default #{@default_max_output}), plus interpreter bounds `:fuel` / `:max_depth`.
  """
  def run(%Washy{} = mod, name, args, opts \\ []) when is_list(args) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    max_out = Keyword.get(opts, :max_output, @default_max_output)

    # validate untrusted structure up front (default on); reject malformed before spending a process
    case if(Keyword.get(opts, :validate, true), do: Nexus.Washy.Validate.validate(mod), else: :ok) do
      {:error, reason} -> {:error, reason}
      :ok -> do_run(mod, name, args, opts, timeout, max_out)
    end
  end

  defp do_run(mod, name, args, opts, timeout, max_out) do
    ctx = Map.new(@ctx_keys, fn k -> {k, Process.get(k)} end)

    task =
      Task.async(fn ->
        Enum.each(ctx, fn {k, v} -> if v != nil, do: Process.put(k, v) end)

        try do
          {result, out} = Washy.call_io(mod, name, args, opts)
          {:ok, result, out}
        rescue
          e in Trap -> {:trap, e.reason}
          # ANY other exception (e.g. an unvalidated module hitting a bad index) is contained here,
          # never propagated to the caller — the run process owns the fault.
          e -> {:error, Exception.message(e)}
        catch
          :throw, {:washy_exit, code} ->
            out = Process.get(:washy_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
            {:exit, code, out}

          kind, reason ->
            {:error, {kind, reason}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result, out}} ->
        {clipped, trunc?} = clip(out, max_out)
        {:ok, result, clipped, %{truncated?: trunc?}}

      {:ok, {:exit, code, out}} ->
        {clipped, _} = clip(out, max_out)
        {:exit, code, clipped}

      {:ok, {:trap, reason}} ->
        {:trap, reason}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:exit, reason} ->
        {:error, reason}

      nil ->
        {:timeout}
    end
  end

  defp clip(bin, max) when byte_size(bin) <= max, do: {bin, false}
  defp clip(bin, max), do: {binary_part(bin, 0, max), true}

  @doc """
  Run a **WASI command module** (stdin → stdout) on Washy — the in-process replacement for
  `Nexus.Sandbox.run_command` (the wasmtime subprocess lane). Handles both shapes:

    * `wasm` (binary) — a self-contained command module (js/ts, a toolkit CLI): `_start`, fed `stdin`.
    * `{:interp, interp_wasm, source}` — an interpreter + its script (python): the source is placed in
      the VFS and the interpreter runs it.

  Returns `{:ok, stdout} | {:error, reason}`. Bounded + BEAM-isolated like every Washy run. Opts:
  `:vfs` (initial files), `:argv`, plus the standard per-run bounds.
  """
  def run_command(spec, stdin \\ "", opts \\ [])

  def run_command(wasm, stdin, opts) when is_binary(wasm) do
    case Nexus.Washy.decode_cached(bytes(wasm)) do
      {:ok, mod} -> exec_module(mod, Keyword.get(opts, :argv, ["cmd"]), stdin, Keyword.get(opts, :vfs, %{}), opts)
      err -> err
    end
  end

  def run_command({:interp, interp, source}, stdin, opts) do
    case Nexus.Washy.decode_cached(bytes(interp)) do
      {:ok, mod} ->
        vfs = Map.put(Keyword.get(opts, :vfs, %{}), "main", source)
        exec_module(mod, Keyword.get(opts, :argv, ["interp", "/work/main"]), stdin, vfs, opts)

      err ->
        err
    end
  end

  # the compiler lanes hand us a PATH to the built wasm (js/python interpreters); accept bytes too
  defp bytes(b) when is_binary(b), do: if(File.regular?(b), do: File.read!(b), else: b)

  defp exec_module(mod, argv, stdin, vfs, opts) do
    # set the per-run context the Sandbox snapshots into its isolated Task
    Process.put(:washy_stdin, stdin)
    Process.put(:washy_argv, argv)
    Process.put(:washy_vfs, vfs)
    Process.put(:washy_backend, :map)
    Process.put(:washy_fds, %{})
    Process.put(:washy_nextfd, 4)

    # tiered transpilation (native-compile hot functions; cached per module). Neutral mechanism, on by
    # default, dialed by the deploy block; bit-identical to pure interpretation.
    # The compiled-program lane is default-ON (wb-lzav/Phase C): a single-purpose compute CLI through
    # bounded prewarm runs near-native, bit-identical to interp — a clean win, so it doesn't wait on the
    # shell-oriented global `washy_transpile` flag. Overridable per-call (`transpile: false`).
    transpile? = Keyword.get(opts, :transpile, true)

    # A compiled CLI is one main() with an internal hot loop — call-count tiering never fires (main runs
    # once). So for this lane we PREWARM bounded modules up front: small single-purpose programs go native
    # from call 1 (compile cached cross-run); big multicall modules (coreutils) skip and stay lazy/interp.
    if transpile?, do: Nexus.Washy.Transpile.prewarm_bounded(mod, "_start")

    case run(mod, "_start", [], Keyword.put(opts, :transpile, transpile?)) do
      {:ok, _r, out, _meta} -> {:ok, out}
      {:exit, _code, out} -> {:ok, out}
      {:trap, reason} -> {:error, {:trap, reason}}
      {:timeout} -> {:error, :timeout}
      {:error, e} -> {:error, e}
    end
  end
end

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
end

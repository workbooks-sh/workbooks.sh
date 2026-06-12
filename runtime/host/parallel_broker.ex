defmodule Workbooks.ParallelBroker do
  @moduledoc """
  wb-broker THREADING-FALLBACK (Stone 4) — brokered DATA-PARALLELISM. A single wasm instance can't spawn
  threads, so the host runs a command over N inputs CONCURRENTLY across BEAM processes (each a fresh,
  isolated sandbox) and gathers the results. This is the host-brokered substitute for within-program
  threads: the parallelism lives in the host (Task.async_stream over fresh instances), the guest stays
  single-threaded and sandboxed.

  Every task is a full Workbooks.ExecBroker.exec — so the entire exec security cadence (default-deny /
  registered-only / no-injection / output-cap) applies per task. Extra parallelism-specific limits:
    * `:allow` DEFAULT-DENY (same `commands` grant as exec).
    * `:max_inputs` — cap the fan-out (a guest can't request a million parallel tasks).
    * `:max_concurrency` — cap simultaneous tasks (CPU/memory bound); excess queue.
    * per-task `:timeout` (slow tasks are killed, not left to hang).
  """
  alias Workbooks.ExecBroker

  @max_inputs 1024
  @max_concurrency 16

  @doc """
  Run `name` over each input in `inputs` CONCURRENTLY. Each input is that task's stdin; `:argv` is shared
  across all tasks. Returns `{:ok, [result]}` (per-task `{:ok, out} | {:error, reason}`, order-preserving)
  | `{:error, reason}`.
  """
  def map(name, inputs, opts \\ []) when is_binary(name) and is_list(inputs) do
    allow = Keyword.get(opts, :allow, false)
    argv = Keyword.get(opts, :argv, [])
    max_inputs = Keyword.get(opts, :max_inputs, @max_inputs)
    max_conc = Keyword.get(opts, :max_concurrency, @max_concurrency)
    timeout = Keyword.get(opts, :timeout, 30_000)

    cond do
      not allow -> {:error, :denied}
      length(inputs) > max_inputs -> {:error, :too_many_inputs}
      true -> {:ok, run(name, inputs, argv, max_conc, timeout)}
    end
  end

  defp run(name, inputs, argv, max_conc, timeout) do
    inputs
    |> Task.async_stream(
      fn input -> ExecBroker.exec(name, argv, input, allow: true) end,
      max_concurrency: max_conc,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.map(fn
      {:ok, {:ok, out}} -> {:ok, out}
      {:ok, {:error, reason}} -> {:error, reason}
      {:exit, reason} -> {:error, {:task_failed, reason}}
    end)
  end
end

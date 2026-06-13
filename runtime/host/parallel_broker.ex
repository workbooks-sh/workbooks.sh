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
    principal = Keyword.get(opts, :principal)
    depth = Keyword.get(opts, :depth, 0)

    cond do
      principal && Workbooks.Revocation.revoked?(principal) -> {:error, :revoked}
      not allow -> {:error, :denied}
      length(inputs) > max_inputs -> {:error, :too_many_inputs}
      true -> {:ok, run(name, inputs, argv, max_conc, timeout, principal, depth)}
    end
  end

  @doc """
  Parse the wasm wire request for host_parallel_map (length-prefixed LE, binary-safe):

      [name_len][name][argc][(arg_len)(arg)]*[ninputs][(input_len)(input)]*

  Returns `{:ok, name, argv, inputs}` | `:error`.
  """
  def parse_map_request(bin) when is_binary(bin) do
    with <<nlen::little-32, name::binary-size(nlen), argc::little-32, r1::binary>> <- bin,
         {:ok, argv, r2} <- lp_list(r1, argc, []),
         <<nin::little-32, r3::binary>> <- r2,
         {:ok, inputs, _} <- lp_list(r3, nin, []) do
      {:ok, name, argv, inputs}
    else
      _ -> :error
    end
  end

  def parse_map_request(_), do: :error

  @doc """
  Encode `[{:ok, out} | {:error, _}]` results back for the guest:

      [nresults][ (len:i32, -1 = error)(result_bytes) ]*

  -1 length marks a failed task (no body follows). Order matches the inputs.
  """
  def encode_results(results) when is_list(results) do
    body =
      Enum.map_join(results, "", fn
        {:ok, out} -> <<byte_size(out)::little-signed-32, out::binary>>
        {:error, _} -> <<-1::little-signed-32>>
      end)

    <<length(results)::little-signed-32, body::binary>>
  end

  defp lp_list(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp lp_list(<<len::little-32, item::binary-size(len), rest::binary>>, n, acc) when n > 0,
    do: lp_list(rest, n - 1, [item | acc])

  defp lp_list(_, _, _), do: :error

  defp run(name, inputs, argv, max_conc, timeout, principal, depth) do
    inputs
    |> Task.async_stream(
      fn input -> ExecBroker.exec(name, argv, input, allow: true, principal: principal, depth: depth) end,
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

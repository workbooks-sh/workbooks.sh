defmodule Workbooks.Fabric do
  @moduledoc """
  The distributed-compute primitive (wb-rhs.9): fan a command/kernel over N inputs
  across ISOLATED WASM instances, at a chosen `(width, tier)`. This is the general
  substrate — the media/render fabric (frames) is just ONE consumer of it, and the
  reason to build this BEFORE the media work: any intensive toolkit (image batches,
  parsing, transforms, search) distributes the same way.

  THE TWO KNOBS (one surface, see [[toolkit-isolation-model]]):
    * WIDTH  — how many inputs run concurrently (throughput / distribution).
    * TIER   — the isolation/containment of each worker (wb-rhs.10):
        :instance (default) — each input runs in its own wasmtime instance, fanned
                              across BEAM schedulers/cores. Same VM; memory-
                              sandboxed, trap-contained. Strong + cheap.
        :os_process / :node / :container — heavier tiers (wb-rhs.10); NOT yet wired.

  Distribution and isolation are the SAME primitive: width is "how many contexts",
  tier is "how isolated each". At :node, the two MERGE — a peer BEAM node is both
  stronger isolation AND cross-machine scale (the render farm across machines).

  Each worker is `CommandRegistry.run/5` — already its own isolated instance with a
  memory cap + wall-clock. So `:instance` fan-out is correct + isolated by
  construction; the BEAM scheduler spreads the workers across cores. A failing or
  timing-out input degrades to an error in its slot — it never takes down its
  siblings (per-task isolation is the whole point).
  """

  @default_width 16
  @default_timeout 60_000

  @doc """
  Map a registered command over `inputs`, concurrently, returning results IN ORDER.

  `inputs` is a list where each item is either:
    * a binary — the stdin for that worker (argv = []), or
    * a `{stdin, argv}` tuple — stdin + the command's argv for that worker.

  opts:
    * `:width`   — max concurrent workers (default #{@default_width}).
    * `:tier`    — worker isolation (default `:instance`; others are wb-rhs.10).
    * `:timeout` — per-worker wall-clock ms (default #{@default_timeout}).
    * `:dirs`, `:ropts` — passed through to CommandRegistry.run/5.

  Returns `{:ok, [result]}` where each result is `{:ok, stdout} | {:error, reason}`
  (ordered to match `inputs`), or `{:error, {:unsupported_tier, tier}}`.
  """
  def map(name, inputs, opts \\ []) when is_binary(name) and is_list(inputs) do
    case opts[:tier] || :instance do
      :instance -> {:ok, map_instances(name, inputs, opts)}
      other -> {:error, {:unsupported_tier, other}}
    end
  end

  defp map_instances(name, inputs, opts) do
    width = opts[:width] || @default_width
    timeout = opts[:timeout] || @default_timeout
    dirs = opts[:dirs] || []
    ropts = opts[:ropts] || []

    inputs
    |> Task.async_stream(
      fn item ->
        {stdin, argv} = normalize(item)
        Workbooks.CommandRegistry.run(name, stdin, argv, dirs, ropts)
      end,
      max_concurrency: width,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, :timeout} -> {:error, :worker_timeout}
      {:exit, reason} -> {:error, {:worker_exit, reason}}
    end)
  end

  defp normalize({stdin, argv}) when is_binary(stdin) and is_list(argv), do: {stdin, argv}
  defp normalize(stdin) when is_binary(stdin), do: {stdin, []}
end

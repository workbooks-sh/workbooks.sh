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
    # Commands run as per-call subprocess wasmtime (CommandRegistry.run →
    # run_wasmtime) — native tier :os_process. tier: :node runs each on a separate
    # BEAM VM (Workbooks.IsolationNode) for full VM isolation (wb-pkh.5).
    case resolve_for(:map, opts[:tier] || :os_process) do
      {:ok, tier} -> {:ok, map_instances(name, inputs, tier, opts)}
      {:error, _} = err -> err
    end
  end

  defp map_instances(name, inputs, tier, opts) do
    width = opts[:width] || @default_width
    timeout = opts[:timeout] || @default_timeout
    dirs = opts[:dirs] || []
    ropts = opts[:ropts] || []

    runner =
      case tier do
        :node -> fn stdin, argv -> Workbooks.IsolationNode.run(name, stdin, argv) end
        _ -> fn stdin, argv -> Workbooks.CommandRegistry.run(name, stdin, argv, dirs, ropts) end
      end

    inputs
    |> Task.async_stream(
      fn item ->
        {stdin, argv} = normalize(item)
        runner.(stdin, argv)
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

  @doc """
  Map a `bytes → bytes` KERNEL (wb-rhs.5) over `inputs` — the render-fabric shape.
  Opens a POOL of `:width` persistent kernel instances (Workbooks.Kernel,
  instantiate-once), partitions `inputs` into contiguous slices, and runs each
  slice through its own kernel concurrently. So each frame pays one function call
  + arena copy (not a fresh instance + stdio), and the slices run in parallel
  across BEAM schedulers — persistent WITHIN a worker, distributed ACROSS workers.
  This is what a CPU renderer is: N frame-kernels, frames fanned across them.

  `inputs` is a list of binaries (one frame each). Returns `{:ok, [result]}` in
  order, each `{:ok, out_bytes} | {:error, reason}`. Same `(width, tier)` surface
  as `map/3`; `:instance` tier today (heavier tiers = wb-rhs.10).
  """
  def map_kernel(wasm_bytes, inputs, opts \\ []) when is_binary(wasm_bytes) and is_list(inputs) do
    # Kernels are persistent in-VM Wasmex instances — native tier :instance. :node
    # runs the persistent kernel on a separate BEAM VM (wb-1mh).
    case resolve_for(:map_kernel, opts[:tier] || :instance) do
      {:ok, :instance} -> {:ok, map_kernel_instances(wasm_bytes, inputs, opts)}
      {:ok, :node} -> {:ok, Workbooks.IsolationNode.run_kernel(wasm_bytes, inputs, opts)}
      {:error, _} = err -> err
    end
  end

  # Each fan-out function honors only the tier its execution shape can run at
  # today (commands = subprocess/:os_process, kernels = in-VM/:instance). A
  # mismatched-but-real tier gets a pointed reason; node/container/unknown defer
  # to Isolation.resolve (planned/unknown).
  defp resolve_for(:map, :os_process), do: {:ok, :os_process}

  defp resolve_for(:map, :instance),
    do: {:error, {:tier_mismatch, :instance, "commands run per-call as :os_process (subprocess wasmtime); for the in-VM :instance tier use map_kernel"}}

  defp resolve_for(:map_kernel, :instance), do: {:ok, :instance}

  defp resolve_for(:map_kernel, :os_process),
    do: {:error, {:tier_mismatch, :os_process, "kernels need a persistent in-VM :instance; :os_process would respawn per frame and lose reuse"}}

  defp resolve_for(:map_kernel, :node), do: {:ok, :node}

  defp resolve_for(:map_kernel, :container),
    do: {:error, {:tier_unsupported_for_kernel, :container, "running a persistent kernel in a per-call :container is not built (kernels use :instance or :node)"}}

  defp resolve_for(_fn, tier), do: Workbooks.Isolation.resolve(tier)

  defp map_kernel_instances(_wasm, [], _opts), do: []

  defp map_kernel_instances(wasm, inputs, opts) do
    width = min(opts[:width] || @default_width, length(inputs))
    per = div(length(inputs) + width - 1, width)
    timeout = opts[:timeout] || @default_timeout

    inputs
    |> Enum.chunk_every(per)
    |> Task.async_stream(
      fn chunk ->
        # One persistent kernel per slice — opened once, called per frame, closed.
        case Workbooks.Kernel.open(wasm, opts) do
          {:ok, k} ->
            try do
              Enum.map(chunk, fn frame -> Workbooks.Kernel.call(k, frame) end)
            after
              Workbooks.Kernel.close(k)
            end

          {:error, reason} ->
            Enum.map(chunk, fn _ -> {:error, {:kernel_open_failed, reason}} end)
        end
      end,
      max_concurrency: width,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.flat_map(fn
      {:ok, results} -> results
      {:exit, reason} -> [{:error, {:worker_exit, reason}}]
    end)
  end
end

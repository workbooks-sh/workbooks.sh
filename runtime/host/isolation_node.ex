defmodule Workbooks.IsolationNode do
  @moduledoc """
  The `:node` isolation tier (wb-pkh.5) — run a command on a SEPARATE BEAM VM (a
  `:peer` node) so its wasmtime execution is fully VM-isolated: its own scheduler
  + heap, and a NIF-level crash kills only the peer, not the runtime. This is the
  heaviest in-BEAM tier and the point where isolation and DISTRIBUTION merge — a
  peer node can be local OR on another machine (the render-farm-across-boxes case).

  A single peer is started lazily and REUSED (peer startup is ~100s of ms). The
  parent's code paths are propagated and `:workbooks` started on the peer, so it
  can run the same CommandRegistry/PackageManager path the local node does. The
  command's `.wasm` lives on the shared filesystem, so the peer resolves it itself.

  Distribution: if the local node isn't alive, we start it (longname on 127.0.0.1)
  lazily — `:node` requires a distributed runtime. In production the runtime is
  already a named node; here we self-bootstrap for local isolation.
  """
  use GenServer

  @name __MODULE__

  def start_link(_ \\ nil), do: GenServer.start_link(__MODULE__, nil, name: @name)

  @doc """
  Run a registered command on the peer node. Same contract as
  CommandRegistry.run/3 but executed in a separate VM. `{:ok, stdout}` | `{:error, _}`.
  """
  def run(command, input, argv \\ []) do
    ensure_started()
    GenServer.call(@name, {:run, command, input, argv}, 60_000)
  end

  @doc """
  Run a `bytes → bytes` KERNEL on the peer node (wb-1mh): the kernel is
  instantiated + looped over `inputs` ENTIRELY on the separate BEAM VM (one erpc,
  the hot loop stays on the peer). Returns the per-input results in order, or an
  error if the tier is unavailable.
  """
  def run_kernel(wasm_bytes, inputs, opts \\ []) do
    ensure_started()
    GenServer.call(@name, {:run_kernel, wasm_bytes, inputs, opts}, 120_000)
  end

  @doc "Is the :node tier usable here (can we bring up distribution + a peer)?"
  def available? do
    ensure_started()
    GenServer.call(@name, :available?, 30_000)
  end

  defp ensure_started do
    case Process.whereis(@name) do
      nil -> start_link()
      _ -> :ok
    end
  end

  # ── server ────────────────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{peer: nil, node: nil}}

  @impl true
  def handle_call(:available?, _from, state) do
    case ensure_peer(state) do
      {:ok, state} -> {:reply, true, state}
      {:error, _reason, state} -> {:reply, false, state}
    end
  end

  @impl true
  def handle_call({:run, command, input, argv}, _from, state) do
    case ensure_peer(state) do
      {:ok, %{node: node} = state} ->
        result =
          try do
            # The peer's command registry is its own (:persistent_term per node);
            # builtins (jq/grep/upper) are already there, but a DYNAMIC command (the
            # third-party case) must be synced. Its content-addressed .wasm is on the
            # shared filesystem, so we just replay the registry entry on the peer.
            sync_command(node, command)
            :erpc.call(node, Workbooks.CommandRegistry, :run, [command, input, argv], 55_000)
          catch
            :error, reason -> {:error, {:peer_call_failed, reason}}
            kind, reason -> {:error, {:peer_call_failed, {kind, reason}}}
          end

        {:reply, result, state}

      {:error, reason, state} ->
        {:reply, {:error, {:node_tier_unavailable, reason}}, state}
    end
  end

  @impl true
  def handle_call({:run_kernel, wasm_bytes, inputs, opts}, _from, state) do
    case ensure_peer(state) do
      {:ok, %{node: node} = state} ->
        # Kernel opts only (arena/entry/offsets); drop tier/vfs/etc. Run the whole
        # open→loop→close batch on the peer in one call.
        kopts = Keyword.take(opts, [:arena, :entry, :in_ptr_fn, :out_ptr_fn, :in_off, :out_off, :timeout])

        result =
          try do
            :erpc.call(node, Workbooks.Kernel, :run_batch, [wasm_bytes, inputs, kopts], 110_000)
          catch
            kind, reason -> Enum.map(inputs, fn _ -> {:error, {:peer_kernel_failed, {kind, reason}}} end)
          end

        {:reply, result, state}

      {:error, reason, state} ->
        {:reply, {:error, {:node_tier_unavailable, reason}}, state}
    end
  end

  # Replay a dynamically-registered command's entry on the peer (idempotent).
  # Builtins (the {:src,...} shape) are compiled into the registry on every node.
  defp sync_command(node, command) do
    case Workbooks.CommandRegistry.current(command) do
      {:wasm, path, mode} -> :erpc.call(node, Workbooks.CommandRegistry, :register, [command, path, mode])
      {:wasm, path, mode, opts} -> :erpc.call(node, Workbooks.CommandRegistry, :register, [command, path, mode, opts])
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # Lazily ensure a live peer (start distribution if needed, then a peer node with
  # the app's code paths + :workbooks started). Cached for reuse.
  defp ensure_peer(%{node: node} = state) when not is_nil(node) do
    if node in Node.list(:connected), do: {:ok, state}, else: start_peer(%{state | peer: nil, node: nil})
  end

  defp ensure_peer(state), do: start_peer(state)

  defp start_peer(state) do
    with :ok <- ensure_distribution(),
         {:ok, pid, node} <- :peer.start_link(%{name: :peer.random_name(), host: ~c"127.0.0.1", longnames: true}) do
      # Propagate code paths so Elixir + Workbooks load, then start the app on the peer.
      :erpc.call(node, :code, :add_pathsa, [:code.get_path()])
      :erpc.call(node, Application, :ensure_all_started, [:workbooks])
      {:ok, %{state | peer: pid, node: node}}
    else
      {:error, reason} -> {:error, reason, state}
      other -> {:error, other, state}
    end
  end

  # Start the local node as distributed if it isn't already (required for peers).
  defp ensure_distribution do
    if Node.alive?() do
      :ok
    else
      name = :"wb-iso-#{:erlang.unique_integer([:positive])}@127.0.0.1"

      case :net_kernel.start(name, %{name_domain: :longnames}) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, reason} -> {:error, {:no_distribution, reason}}
      end
    end
  end
end

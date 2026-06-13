defmodule Workbooks.BrokerTables do
  @moduledoc """
  wb self-audit: a LONG-LIVED owner for the broker ETS tables (rate-limiter, broker-audit counters + ring).

  THE BUG THIS CLOSES: those tables were created lazily by whatever process first touched them. Broker ops
  run inside TRANSIENT processes (e.g. ParallelBroker's `Task.async_stream`, the app-host's per-request
  tasks), so the first caller could be a short-lived Task — and a `:named_table` is DELETED when its owning
  process dies. The next caller then hit `:ets.update_counter` on a vanished table → ArgumentError crash
  (and silently lost rate-limit/audit state). Under concurrency this is frequent.

  FIX: this GenServer owns the tables for the lifetime of the app. `ensure/2` lazily creates a table HERE (so
  it's owned by this never-dying process, not the caller) and is safe to call from any process. The GenServer
  is started unlinked from its first caller (`GenServer.start`, name-registered) so an ad-hoc start from a
  transient task still outlives that task; in production it's also a supervised child.
  """
  use GenServer

  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Return `name`, guaranteeing the ETS table exists and is owned by this long-lived process. `opts` are the
  `:ets.new` options used on first creation. Safe under concurrency (creation is serialized in the GenServer).
  """
  def ensure(name, opts) do
    if :ets.whereis(name) == :undefined do
      GenServer.call(owner(), {:create, name, opts})
    end

    name
  end

  # the owner process — started UNLINKED (survives a transient caller) + name-registered (one wins a race)
  defp owner do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:create, name, opts}, _from, state) do
    # double-check under the serializing call (another caller may have created it first)
    if :ets.whereis(name) == :undefined, do: :ets.new(name, opts)
    {:reply, :ok, state}
  end
end

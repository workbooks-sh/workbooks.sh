defmodule Workbooks.Instance.Supervisor do
  @moduledoc "Per-tenant DynamicSupervisor over running Instances; lookup via Registry."
  use DynamicSupervisor

  def start_link(_), do: DynamicSupervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Start a new Instance from component bytes."
  def start_instance(id, wasm_bytes, opts \\ []) do
    DynamicSupervisor.start_child(__MODULE__, {Workbooks.Instance, {id, wasm_bytes, opts}})
  end

  def stop_instance(id) do
    case Registry.lookup(Workbooks.Instance.Registry, id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> :error
    end
  end

  def count, do: DynamicSupervisor.count_children(__MODULE__).active
end

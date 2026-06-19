defmodule Nexus.ControlPlane.Store do
  @moduledoc """
  The durable owner of the control-plane registry — a DETS table on the persistent volume
  (`data_dir/control-plane.dets`). DETS rows survive restarts, so the control-plane never loses its
  nexus fleet / workspace registry on a redeploy or machine churn (the ETS version did).

  A DETS table is closed when its OPENING process dies, so this long-lived GenServer owns it; reads
  and writes go through `:dets` directly from request processes (DETS serializes them). Records are
  stored as Erlang terms (`:dets` values), not JSON — internal storage, type-preserving, no sidecar.
  """
  use GenServer

  @table :nexus_control_plane

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def table, do: @table

  @impl true
  def init(:ok) do
    File.mkdir_p!(Nexus.Config.data_dir())
    path = Nexus.Config.data_dir() |> Path.join("control-plane.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table, file: path, type: :set, auto_save: 10_000)
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.sync(@table)
    :dets.close(@table)
  end
end

defmodule Nexus.ControlPlaneDurabilityTest do
  use ExUnit.Case, async: false
  alias Nexus.ControlPlane, as: CP

  test "records survive a Store restart (DETS is durable across restarts)" do
    {:ok, _} = CP.put("org_dur", :nexus, "nx_dur1", %{name: "Durable"})
    assert {:ok, %{name: "Durable"}} = CP.get("org_dur", :nexus, "nx_dur1")

    # Simulate a restart: stop the owning GenServer (closes DETS, syncing to disk) and restart it.
    :ok = Supervisor.terminate_child(Nexus.Supervisor, Nexus.ControlPlane.Store)
    {:ok, _} = Supervisor.restart_child(Nexus.Supervisor, Nexus.ControlPlane.Store)

    # The record is still there — it came back off disk, not memory.
    assert {:ok, %{name: "Durable"}} = CP.get("org_dur", :nexus, "nx_dur1")
  after
    CP.delete("org_dur", :nexus, "nx_dur1")
  end
end

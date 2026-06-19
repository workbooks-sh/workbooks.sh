defmodule Nexus.ProvisionerTest do
  use ExUnit.Case, async: false
  alias Nexus.ControlPlane, as: CP
  alias Nexus.Provisioner, as: P

  # A recording Fly stub (process-dict; provision runs in the test process). Records every call so we
  # can assert what DID and DID NOT hit Fly, and capture the machine config to inspect secrets.
  defmodule RecFly do
    def reset, do: Process.put(:fly, [])
    def calls, do: Enum.reverse(Process.get(:fly, []))
    defp rec(c), do: Process.put(:fly, [c | Process.get(:fly, [])])
    def create_app(app, org, _), do: (rec({:create_app, app, org}); {:ok, %{}})
    def create_machine(app, config, _), do: (rec({:create_machine, app, config}); {:ok, %{"id" => "m_" <> app}})
    def destroy_machine(a, i, _), do: (rec({:destroy_machine, a, i}); {:ok, %{}})
    def delete_app(a, _), do: (rec({:delete_app, a}); {:ok, %{}})
    def start_machine(a, i, _), do: (rec({:start_machine, a, i}); {:ok, %{}})
    def stop_machine(a, i, _), do: (rec({:stop_machine, a, i}); {:ok, %{}})
    def get_machine(a, i, _), do: (rec({:get_machine, a, i}); {:ok, %{"state" => "started"}})
  end

  setup do
    CP.reset()
    RecFly.reset()
    :ok
  end

  defp bearer_of(config), do: config["env"]["WB_PUBLIC_BEARER"]

  test "a malformed org is rejected BEFORE any Fly call (path-escape can't reach storage prefix)" do
    assert P.provision("a/../shared", fly: RecFly) == {:error, :invalid_org}
    assert P.provision("", fly: RecFly) == {:error, :no_org}
    assert RecFly.calls() == [], "Fly was called for an invalid org"
  end

  test "per-nexus bearer is fresh, unique, and NEVER stored in the registry" do
    {:ok, a} = P.provision("org_secrets", fly: RecFly)
    {:ok, b} = P.provision("org_secrets", fly: RecFly)

    configs = for {:create_machine, _app, cfg} <- RecFly.calls(), do: cfg
    [bearer_a, bearer_b] = Enum.map(configs, &bearer_of/1)
    assert is_binary(bearer_a) and byte_size(bearer_a) > 20
    assert bearer_a != bearer_b, "two provisions reused the same bearer"

    # The bearer lives ONLY on the machine config — never in the registry row.
    refute Map.has_key?(a, :bearer)
    refute a |> Map.values() |> Enum.member?(bearer_a)
    {:ok, stored} = CP.get("org_secrets", :nexus, a.id)
    refute stored |> Map.values() |> Enum.member?(bearer_a)
    # storage prefix is the tenant's own
    assert bearer_a && Enum.find(configs, &(&1["env"]["WB_S3_PREFIX"] == "tenants/org_secrets/"))
  end

  test "lifecycle verbs are ownership-gated — a foreign org touches NOTHING on Fly" do
    {:ok, nx} = P.provision("org_owner", fly: RecFly)
    RecFly.reset()

    # org_attacker knows the exact id but does not own it → no Fly action, not_found.
    assert P.teardown(nx.id, "org_attacker", fly: RecFly) == {:error, :not_found}
    assert P.wake(nx.id, "org_attacker", fly: RecFly) == {:error, :not_found}
    assert P.sleep(nx.id, "org_attacker", fly: RecFly) == {:error, :not_found}
    assert RecFly.calls() == [], "a non-owner reached Fly — ownership gate breached!"

    # The owner still has its nexus, intact.
    assert {:ok, _} = CP.get("org_owner", :nexus, nx.id)
  end

  test "owner can wake/sleep/teardown — state transitions + Fly calls happen" do
    {:ok, nx} = P.provision("org_life", fly: RecFly)
    assert {:ok, %{state: "running"}} = P.wake(nx.id, "org_life", fly: RecFly)
    assert {:ok, %{state: "stopped"}} = P.sleep(nx.id, "org_life", fly: RecFly)
    assert {:ok, :torn_down} = P.teardown(nx.id, "org_life", fly: RecFly)
    assert CP.get("org_life", :nexus, nx.id) == {:error, :not_found}
  end
end

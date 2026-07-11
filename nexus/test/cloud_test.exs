defmodule Nexus.CloudTest do
  use ExUnit.Case, async: false
  alias Nexus.Cloud
  alias Nexus.ControlPlane, as: CP

  defp stub do
    fn method, url, _headers, _body ->
      cond do
        String.contains?(url, "wait?state=") -> {:ok, {200, ~s({"ok":true})}}
        method == :post and String.ends_with?(url, "/apps") -> {:ok, {201, ~s({"name":"cust-t1"})}}
        method == :post and String.ends_with?(url, "/volumes") -> {:ok, {201, ~s({"id":"vol_1"})}}
        method == :post and String.ends_with?(url, "/machines") -> {:ok, {201, ~s({"id":"m_1","state":"created"})}}
        method == :post and (String.ends_with?(url, "/start") or String.ends_with?(url, "/stop") or String.ends_with?(url, "/suspend")) ->
          {:ok, {200, ~s({"ok":true})}}

        method == :post and String.contains?(url, "/machines/") -> {:ok, {200, ~s({"id":"m_1","state":"started"})}}
        method == :get and String.contains?(url, "/machines/") ->
          {:ok, {200, ~s({"id":"m_1","state":"started","config":{"image":"registry.fly.io/autopoet:v1"}})}}

        method == :delete -> {:ok, {200, "{}"}}
        true -> {:ok, {200, "{}"}}
      end
    end
  end

  setup do
    CP.reset()
    System.delete_env("FLY_ORG_TOKEN")
    System.delete_env("COMPOSIO_API_KEY")
    :ok
  end

  test "provision persists the routing map, keyed by tenant, WITHOUT the bearer" do
    {:ok, rec} = Cloud.provision("t1", http: stub(), token: "org-token")
    assert rec.fly_app == Nexus.Cloud.Fly.app_name("t1")
    assert rec.fly_machine == "m_1"
    assert rec.volume == "vol_1"
    refute Map.has_key?(rec, :bearer), "the live bearer must never be persisted in the registry"

    {:ok, stored} = CP.get("t1", :cloud_tenant, "t1")
    refute stored |> Map.values() |> Enum.member?(:bearer)
    assert {:ok, ^rec} = Cloud.get("t1")
  end

  test "provision is idempotent — a second call returns the existing machine, no second machine" do
    {:ok, a} = Cloud.provision("t1", http: stub(), token: "org-token")
    {:ok, b} = Cloud.provision("t1", http: stub(), token: "org-token")
    assert a.fly_app == b.fly_app
    assert a.fly_machine == b.fly_machine
  end

  test "lifecycle verbs update the recorded state" do
    {:ok, _} = Cloud.provision("t1", http: stub(), token: "t")
    assert {:ok, %{state: "running"}} = Cloud.start("t1", http: stub(), token: "t")
    assert {:ok, %{state: "stopped"}} = Cloud.stop("t1", http: stub(), token: "t")
    assert {:ok, %{state: "suspended"}} = Cloud.suspend("t1", http: stub(), token: "t")
  end

  test "status returns the record + live machine" do
    app = Nexus.Cloud.Fly.app_name("t1")
    {:ok, _} = Cloud.provision("t1", http: stub(), token: "t")

    assert {:ok, %{record: %{fly_app: ^app}, machine: %{"state" => "started"}}} =
             Cloud.status("t1", http: stub(), token: "t")
  end

  test "update_image rolls the machine and records the new image" do
    {:ok, _} = Cloud.provision("t1", http: stub(), token: "t")
    assert {:ok, %{image: "registry.fly.io/autopoet:v2"}} =
             Cloud.update_image("t1", "registry.fly.io/autopoet:v2", http: stub(), token: "t")

    assert {:ok, %{image: "registry.fly.io/autopoet:v2"}} = Cloud.get("t1")
  end

  test "teardown destroys the machine and deletes the registry row" do
    {:ok, _} = Cloud.provision("t1", http: stub(), token: "t")
    assert {:ok, :torn_down} = Cloud.teardown("t1", http: stub(), token: "t")
    assert Cloud.get("t1") == {:error, :not_found}
  end

  test "tenant records are isolated — one tenant can never read another's machine map" do
    {:ok, _} = Cloud.provision("t1", http: stub(), token: "t")
    # t2's scope cannot resolve t1's record (structural {tenant,kind,id} keying).
    assert Cloud.get("t2") == {:error, :not_found}
    assert CP.get("t2", :cloud_tenant, "t1") == {:error, :not_found}
  end

  test "no-op-safe end to end: no token, no transport → provision skips, nothing persisted" do
    assert Cloud.provision("fresh-tenant") == {:skip, :fly_not_configured}
    assert Cloud.get("fresh-tenant") == {:error, :not_found}
  end

  test "lifecycle on an unknown tenant is not_found (no Fly action)" do
    assert Cloud.status("nobody", http: stub(), token: "t") == {:error, :not_found}
    assert Cloud.teardown("nobody", http: stub(), token: "t") == {:error, :not_found}
  end
end

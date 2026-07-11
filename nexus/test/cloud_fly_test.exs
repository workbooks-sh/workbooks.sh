defmodule Nexus.Cloud.FlyTest do
  use ExUnit.Case, async: false
  alias Nexus.Cloud.Fly

  # A canned Fly transport — routes by (method, url) so the whole provision/lifecycle path runs with no
  # network. Distinct ids let us assert what was parsed out of each response.
  defp stub do
    fn method, url, _headers, _body ->
      cond do
        String.contains?(url, "wait?state=") -> {:ok, {200, ~s({"ok":true})}}
        method == :post and String.ends_with?(url, "/apps") -> {:ok, {201, ~s({"name":"cust-t1"})}}
        method == :post and String.ends_with?(url, "/volumes") -> {:ok, {201, ~s({"id":"vol_1"})}}
        method == :post and String.ends_with?(url, "/machines") -> {:ok, {201, ~s({"id":"m_1","state":"created"})}}
        method == :post and (String.ends_with?(url, "/start") or String.ends_with?(url, "/stop") or String.ends_with?(url, "/suspend")) ->
          {:ok, {200, ~s({"ok":true})}}

        # update_machine re-POSTs the full config to /machines/<id>
        method == :post and String.contains?(url, "/machines/") -> {:ok, {200, ~s({"id":"m_1","state":"started"})}}
        method == :get and String.contains?(url, "/machines/") ->
          {:ok, {200, ~s({"id":"m_1","state":"started","config":{"image":"registry.fly.io/autopoet:v1"}})}}

        method == :delete -> {:ok, {200, "{}"}}
        true -> {:ok, {200, "{}"}}
      end
    end
  end

  setup do
    # Guarantee the no-op gate really has no ambient token.
    System.delete_env("FLY_ORG_TOKEN")
    :ok
  end

  test "no-op-safe: absent token AND no injected transport → {:skip, :fly_not_configured}" do
    assert Fly.provision("t1") == {:skip, :fly_not_configured}
    assert Fly.status("cust-t1", "m_1") == {:skip, :fly_not_configured}
    assert Fly.teardown("cust-t1", "m_1") == {:skip, :fly_not_configured}
  end

  test "a blank/invalid tenant is rejected BEFORE any Fly call" do
    assert Fly.provision("", http: stub()) == {:error, :no_tenant}
    assert Fly.provision("a/../b", http: stub()) == {:error, :invalid_tenant}
    # An org ID may be MixedCase (app_name/1 slugs it to a Fly-safe label); a space/control char is not.
    assert Fly.provision("bad tenant", http: stub()) == {:error, :invalid_tenant}
  end

  test "provision creates app+volume+machine, waits, and returns the routing map (bearer present, fresh)" do
    {:ok, m} = Fly.provision("t1", http: stub(), token: "org-token")
    # app_name/1 is part of the provider contract: slug + 8-char hash of the original id.
    assert m.fly_app == Fly.app_name("t1")
    assert m.fly_machine == "m_1"
    assert m.volume == "vol_1"
    # THE LINE: no product image default — the neutral runtime image (deploy-config driven).
    assert m.image == Nexus.Config.runtime_image()
    assert m.state == "started"
    assert is_binary(m.bearer) and byte_size(m.bearer) > 20

    {:ok, m2} = Fly.provision("t1", http: stub(), token: "org-token")
    assert m.bearer != m2.bearer, "bearer must be freshly minted per provision"
  end

  test "the machine config carries autopoet env + suspend/autostart + the mounted volume" do
    # Capture the create_machine body by sniffing the transport.
    parent = self()

    http = fn method, url, headers, body ->
      if method == :post and String.ends_with?(url, "/machines"), do: send(parent, {:machine_body, body})
      stub().(method, url, headers, body)
    end

    {:ok, _} = Fly.provision("t1", http: http, token: "org-token")
    assert_receive {:machine_body, body}
    cfg = Jason.decode!(body)["config"]

    assert cfg["image"] == Nexus.Config.runtime_image()
    assert cfg["env"]["NEXUS_TENANT"] == "t1"
    assert cfg["env"]["WB_DATA"] == "/data"
    assert is_binary(cfg["env"]["WB_PUBLIC_BEARER"])
    assert [%{"volume" => "vol_1", "path" => "/data"}] = cfg["mounts"]
    svc = hd(cfg["services"])
    assert svc["autostop"] == "suspend" and svc["autostart"] == true
  end

  test "provision sends the dedicated 6PN network on app create" do
    parent = self()

    http = fn method, url, headers, body ->
      if method == :post and String.ends_with?(url, "/apps"), do: send(parent, {:app_body, body})
      stub().(method, url, headers, body)
    end

    {:ok, _} = Fly.provision("t1", http: http, token: "org-token")
    assert_receive {:app_body, body}
    assert Jason.decode!(body)["network"] == Fly.app_name("t1")
  end

  test "lifecycle verbs + update_image + teardown work through the injected transport" do
    assert {:ok, _} = Fly.start("cust-t1", "m_1", http: stub(), token: "t")
    assert {:ok, _} = Fly.stop("cust-t1", "m_1", http: stub(), token: "t")
    assert {:ok, _} = Fly.suspend("cust-t1", "m_1", http: stub(), token: "t")
    assert {:ok, _} = Fly.update_image("cust-t1", "m_1", "registry.fly.io/autopoet:v2", http: stub(), token: "t")
    assert {:ok, :torn_down} = Fly.teardown("cust-t1", "m_1", http: stub(), token: "t")
  end

  test "a mid-flight failure best-effort deletes the app so no orphan is left" do
    parent = self()

    # Volume creation fails → provision must delete the app it already created.
    app = Fly.app_name("t1")

    http = fn method, url, _headers, _body ->
      cond do
        method == :post and String.ends_with?(url, "/apps") -> {:ok, {201, ~s({"name":"#{app}"})}}
        method == :post and String.ends_with?(url, "/volumes") -> {:ok, {500, ~s({"error":"boom"})}}
        method == :delete and String.ends_with?(url, "/apps/" <> app) -> send(parent, :deleted_app); {:ok, {200, "{}"}}
        true -> {:ok, {200, "{}"}}
      end
    end

    assert {:error, _} = Fly.provision("t1", http: http, token: "t")
    assert_receive :deleted_app
  end
end

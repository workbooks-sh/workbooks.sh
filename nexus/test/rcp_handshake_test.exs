defmodule Nexus.RcpHandshakeTest do
  use ExUnit.Case, async: false

  test "GET /.well-known/workbooks-runtime is public + returns a valid handshake doc" do
    port = 4588
    start_supervised!({Nexus.Server, root: File.cwd!(), port: port})
    :inets.start()
    {:ok, {{_, code, _}, _h, body}} =
      :httpc.request(:get, {~c"http://127.0.0.1:#{port}/.well-known/workbooks-runtime", []}, [], [])

    assert code == 200
    doc = Jason.decode!(body)
    assert doc["rcp"] == "1"
    assert doc["tenancy"] in ["single", "multi"]
    assert doc["transports"]["http"] == true
    assert is_list(doc["capabilities"]) and "data" in doc["capabilities"]
    assert doc["auth"]["rung"] in ["trusted", "oidc-jwt"]
  end

  test "control-plane role advertises the platform capability + oidc-jwt rung" do
    prev = Application.get_env(:nexus, :auth)
    on_exit(fn ->
      System.delete_env("WB_CONTROL_PLANE")
      if prev, do: Application.put_env(:nexus, :auth, prev), else: Application.delete_env(:nexus, :auth)
    end)

    System.put_env("WB_CONTROL_PLANE", "1")
    Application.put_env(:nexus, :auth, Nexus.Auth.Jwt)

    caps = Nexus.Rcp.capabilities()
    assert "platform" in caps.capabilities
    assert caps.tenancy == "multi"
    assert caps.auth.rung == "oidc-jwt"
  end
end

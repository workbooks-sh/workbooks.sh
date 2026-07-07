defmodule Nexus.Cloud.ApiTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts Nexus.Cloud.Api.init([])

  defp call(method, path, tenant, roles \\ ["owner"], body \\ nil) do
    c =
      if body,
        do: conn(method, path, Jason.encode!(body)) |> put_req_header("content-type", "application/json"),
        else: conn(method, path)

    c = if tenant, do: assign(c, :tenant, tenant) |> assign(:identity, %{tenant: tenant, user: tenant, roles: roles}), else: c
    Nexus.Cloud.Api.call(c, @opts)
  end

  setup do
    System.delete_env("FLY_ORG_TOKEN")
    System.delete_env("COMPOSIO_API_KEY")
    prev = Application.get_env(:nexus, :auth)
    on_exit(fn ->
      System.delete_env("WB_CONTROL_PLANE")
      if prev, do: Application.put_env(:nexus, :auth, prev), else: Application.delete_env(:nexus, :auth)
    end)

    :ok
  end

  defp enable_cp do
    System.put_env("WB_CONTROL_PLANE", "1")
    # Non-None auth adapter → Nexus.Auth.multi? true, so require_org accepts a real tenant.
    Application.put_env(:nexus, :auth, Nexus.Auth.Bearer)
  end

  test "control-plane off → every route 404s (indistinguishable from a tenant runtime)" do
    System.delete_env("WB_CONTROL_PLANE")
    assert call(:post, "/provision", "t1").status == 404
    assert call(:get, "/tools", "t1").status == 404
  end

  test "control-plane on but no tenant identity → 403 (never wide-open)" do
    enable_cp()
    assert call(:post, "/provision", nil).status == 403
  end

  test "machine mutations are ADMIN-ONLY — a viewer gets 403 (wb-review-A3.F2)" do
    enable_cp()
    Nexus.ControlPlane.reset()

    for {m, p} <- [
          {:post, "/provision"},
          {:post, "/machine/start"},
          {:post, "/machine/stop"},
          {:post, "/machine/suspend"},
          {:post, "/machine/image"},
          {:delete, "/machine"}
        ] do
      assert call(m, p, "t1", ["viewer"]).status == 403,
             "#{m} #{p} must be admin-gated (a viewer could otherwise DoS/RCE the org machine)"
    end
  end

  test "an admin CLEARS the machine gate (reaches the broker, not a 403)" do
    enable_cp()
    Nexus.ControlPlane.reset()
    # admin passes admin_only → Cloud.start reaches the broker; with no FLY token the exact status is a
    # dark-broker/not-found code — the point is it is NOT the 403 a viewer gets (the gate opened).
    assert call(:post, "/machine/start", "t1", ["admin"]).status != 403
  end

  test "tokens absent → the feature is dark: 503 not configured (no network, no crash)" do
    enable_cp()
    Nexus.ControlPlane.reset()
    r = call(:post, "/provision", "t1")
    assert r.status == 503
    assert Jason.decode!(r.resp_body)["error"] == "not configured"

    assert call(:get, "/tools", "t1").status == 503
    assert call(:get, "/tools/mcp?toolkits=github", "t1").status == 503
  end

  test "whitelabel auth_config is admin-only" do
    enable_cp()
    body = %{toolkit: "github", client_id: "c", client_secret: "s", redirect_uri: "https://us/cb"}
    assert call(:post, "/tools/auth_config", "t1", ["viewer"], body).status == 403
  end

  test "POST /machine/image requires an image field" do
    enable_cp()
    assert call(:post, "/machine/image", "t1", ["owner"], %{}).status == 422
  end

  test "unknown route under the mount → 404 json" do
    enable_cp()
    assert call(:get, "/nope", "t1").status == 404
  end
end

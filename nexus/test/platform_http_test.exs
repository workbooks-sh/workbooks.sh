defmodule Nexus.PlatformHttpTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts Nexus.Platform.init([])

  defp call(method, path, org, body \\ nil) do
    c =
      if body do
        conn(method, path, Jason.encode!(body)) |> put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    c = if org, do: assign(c, :tenant, org), else: c
    Nexus.Platform.call(c, @opts)
  end

  setup do
    System.put_env("WB_CONTROL_PLANE", "1")
    prev = Application.get_env(:nexus, :auth)
    Application.put_env(:nexus, :auth, Nexus.Auth.Bearer) # non-None → multi? true
    on_exit(fn ->
      System.delete_env("WB_CONTROL_PLANE")
      if prev, do: Application.put_env(:nexus, :auth, prev), else: Application.delete_env(:nexus, :auth)
    end)
  end

  test "control-plane OFF → every platform route 404s (indistinguishable from a tenant runtime)" do
    System.delete_env("WB_CONTROL_PLANE")
    assert call(:get, "/nexuses", "org_x").status == 404
  end

  test "no real org identity (None auth) → 403, never wide-open" do
    Application.put_env(:nexus, :auth, Nexus.Auth.None)
    assert call(:get, "/nexuses", "org_x").status == 403
  end

  test "missing tenant → 403" do
    assert call(:get, "/nexuses", nil).status == 403
  end

  test "a nexus created by org A is invisible + untouchable to org B over HTTP" do
    created = call(:post, "/nexuses", "org_http_a", %{name: "A-prod"})
    assert created.status == 201
    id = Jason.decode!(created.resp_body)["id"]

    # B lists → does not include A's nexus
    b_list = call(:get, "/nexuses", "org_http_b") |> then(& Jason.decode!(&1.resp_body))
    refute Enum.any?(b_list["nexuses"], &(&1["id"] == id)), "org B saw org A's nexus over HTTP — IDOR!"

    # B GETs A's exact id → 404
    assert call(:get, "/nexuses/#{id}", "org_http_b").status == 404
    # B tries to delete A's nexus → A still has it
    assert call(:delete, "/nexuses/#{id}", "org_http_b").status == 200
    assert call(:get, "/nexuses/#{id}", "org_http_a").status == 200
  end

  test "workspace CRUD round-trips for the owning org" do
    c = call(:post, "/workspaces", "org_ws_a", %{name: "Design", icon: "🎨"})
    assert c.status == 201
    list = call(:get, "/workspaces", "org_ws_a") |> then(& Jason.decode!(&1.resp_body))
    assert Enum.any?(list["workspaces"], &(&1["name"] == "Design"))
  end
end

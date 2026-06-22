defmodule Nexus.SurfaceVisibilityTest do
  # Proves the visibility gate is REAL, not cosmetic: a surface marked private/draft in the control
  # plane is no longer publicly served (the "take a live site down to private" guarantee), while a
  # public surface (or no record) serves unchanged. A request carrying a real authenticated user still
  # reaches a private surface (the owner/member case on an auth-enabled nexus).
  use ExUnit.Case, async: false
  import Plug.Test

  # A stub auth adapter that authenticates every request as a real signed-in user — to exercise the
  # "private surface is still reachable by an authenticated user" path (the trusted default has no users).
  defmodule UserAdapter do
    @behaviour Nexus.Auth
    @impl true
    def authenticate(_conn), do: {:ok, %{tenant: Nexus.Store.default_tenant(), user: "usr_owner"}}
  end

  @opts Nexus.Server.init([])

  setup do
    dir = Path.join(System.tmp_dir!(), "wbvis_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lander"))
    File.write!(Path.join(dir, "lander/index.work"), "# Lander\n\nwelcome to the public site\n")
    Application.put_env(:nexus, :mounts, [{"lander", Path.join(dir, "lander")}])

    org = Nexus.Store.default_tenant()
    # clean slate for this surface's visibility across the run
    Nexus.ControlPlane.delete(org, :visibility, "lander")

    on_exit(fn ->
      Nexus.ControlPlane.delete(org, :visibility, "lander")
      Application.delete_env(:nexus, :mounts)
      File.rm_rf!(dir)
    end)

    {:ok, org: org}
  end

  defp anon(path), do: Nexus.Server.call(conn(:get, path), @opts)

  defp set_vis(org, state), do: Nexus.ControlPlane.put(org, :visibility, "lander", %{id: "lander", state: state})

  test "public (no record) → served to anyone" do
    c = anon("/lander/")
    assert c.status == 200
    assert c.resp_body =~ "<!doctype html>"
  end

  test "explicit public → still served", %{org: org} do
    set_vis(org, "public")
    assert anon("/lander/").status == 200
  end

  test "private → NOT publicly accessible (404), for the root AND its assets", %{org: org} do
    set_vis(org, "private")
    assert anon("/lander/").status == 404
    # the gate covers the whole surface, not just the root — sub-paths are blocked too
    assert anon("/lander/anything.js").status == 404
    refute anon("/lander/").resp_body =~ "welcome to the public site"
  end

  test "draft → NOT publicly accessible (404)", %{org: org} do
    set_vis(org, "draft")
    assert anon("/lander/").status == 404
  end

  test "private → a real authenticated user still reaches it", %{org: org} do
    set_vis(org, "private")
    assert anon("/lander/").status == 404

    prev = Application.get_env(:nexus, :auth)
    Application.put_env(:nexus, :auth, UserAdapter)
    on_exit(fn -> if prev, do: Application.put_env(:nexus, :auth, prev), else: Application.delete_env(:nexus, :auth) end)

    assert Nexus.Server.call(conn(:get, "/lander/"), @opts).status == 200
  end

  test "flipping public → private → public takes it down then restores it", %{org: org} do
    assert anon("/lander/").status == 200
    set_vis(org, "private")
    assert anon("/lander/").status == 404
    set_vis(org, "public")
    assert anon("/lander/").status == 200
  end
end

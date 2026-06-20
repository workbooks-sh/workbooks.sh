defmodule Nexus.MobileSmokeTest do
  @moduledoc """
  Vets the dogfood/mobile receiver's server seam end-to-end against REAL infrastructure (no mocks):
  the token primitive the pairing flow depends on, and the catalog the phone receives. Proves the
  auth-to-nexus claim deterministically without needing a booted simulator to reach a live server.
  """
  use ExUnit.Case, async: false

  @mobile Path.expand("../../dogfood/mobile", __DIR__)
  @org "smoke-org"

  setup do
    # A representative two-surface nexus (one nexus per org → these mounts ARE this org's catalog).
    # mounts + nexus_name are app-env; nexus_emoji + workspaces flow through Nexus.Config (deploy block).
    prev_mounts = Application.get_env(:nexus, :mounts)
    prev_name = Application.get_env(:nexus, :nexus_name)
    prev_emoji = Nexus.Config.nexus_emoji()
    prev_ws = Nexus.Config.workspaces()

    Application.put_env(:nexus, :mounts, [{"", @mobile}, {"cloud", @mobile}, {"docs", @mobile}])
    Application.put_env(:nexus, :nexus_name, "smoke")
    Nexus.Config.put(:nexus_emoji, "🐕")
    Nexus.Config.put(:workspaces, [%{id: "cloud", name: "Cloud", icon: "☁️"}])

    # Compile the mobile workbook → the `Mobile` server module + the `Device` resource.
    Nexus.Compile.workbook(@mobile)

    on_exit(fn ->
      restore_env(:mounts, prev_mounts)
      restore_env(:nexus_name, prev_name)
      Nexus.Config.put(:nexus_emoji, prev_emoji)
      Nexus.Config.put(:workspaces, prev_ws)
    end)

    :ok
  end

  defp restore_env(k, nil), do: Application.delete_env(:nexus, k)
  defp restore_env(k, v), do: Application.put_env(:nexus, k, v)

  test "the dogfooded sign-in page serves the nexus's own auth (email + configured OAuth providers)" do
    Nexus.Config.put(:providers, %{"google" => %{}, "github" => %{}})

    {200, ct, html} = Mobile.connect(%{})
    assert ct =~ "text/html"
    # It posts to the nexus's OWN native auth + mints via the existing session — no bespoke auth.
    assert html =~ "/auth/login"
    assert html =~ "/auth/signup"
    assert html =~ "/mobile/pair"
    # And it offers the configured OAuth providers, same as the dashboard.
    assert %{providers: ps} = Mobile.providers(%{})
    assert "google" in ps and "github" in ps
  end

  test "the auth primitive the pairing flow relies on: a minted wbk_ token resolves to its org + scopes" do
    minted = Nexus.Auth.Token.mint(@org, name: "mobile:iPhone", scopes: ["api", "mobile"])
    assert "wbk_" <> _ = minted.token

    # This is exactly what Nexus.Auth (the plug) does for an inbound `Authorization: Bearer …`,
    # which becomes `req.tenant` in the device.work handlers.
    assert {:ok, identity} = Nexus.Auth.Token.verify(minted.token)
    assert identity.tenant == @org
    assert "mobile" in identity.scopes
  end

  test "pair/1 mints a device-scoped token and seeds the nexus identity for the shell" do
    {201, body} = Mobile.pair(%{tenant: @org, body: %{"name" => "iPhone", "platform" => "ios"}})

    assert "wbk_" <> _ = body.token
    assert "tok_" <> _ = body.device_id
    assert body.nexus.emoji == "🐕"
    # The minted device token resolves back to THIS org (so /mobile/apps is correctly scoped).
    assert {:ok, %{tenant: @org}} = Nexus.Auth.Token.verify(body.token)
  end

  test "apps/1 returns the org's catalog: one launchable tile per mounted surface, workspace-tagged" do
    %{nexus: nexus, apps: apps} = Mobile.apps(%{tenant: @org, body: nil})

    assert nexus.emoji == "🐕"
    ids = Enum.map(apps, & &1.id)
    # Non-root mounts surface as tiles; the empty-name root mount is excluded.
    assert "cloud" in ids
    assert "docs" in ids
    refute "" in ids

    cloud = Enum.find(apps, &(&1.id == "cloud"))
    assert cloud.name == "Cloud"     # workspace name from config
    assert cloud.icon == "☁️"         # workspace icon from config
    assert cloud.path == "/cloud"    # the mount the shell loads the woven island from
    assert cloud.nexus == "smoke"
  end
end

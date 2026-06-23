defmodule Nexus.CompileShareKeyTest do
  use ExUnit.Case, async: false

  # wb-1fgl — the compile lane must be keyed per OWNING WORKSPACE so one tenant's compile storm can't
  # starve another's. (Before: every compile shared a single :shared bucket, so fairness was inert.)

  setup do
    saved = Nexus.Config.workspaces()
    Nexus.Config.put(:workspaces, [%{id: "tenants/acme", name: "Acme", icon: nil}, %{id: "site", name: "Site", icon: nil}])
    on_exit(fn -> Nexus.Config.put(:workspaces, saved) end)
    :ok
  end

  test "keyed by the declared workspace owning the source" do
    assert Nexus.Compile.compile_share_key(%{src: "/data/wb/tenants/acme/widgets/x.work"}) == "tenants/acme"
    assert Nexus.Compile.compile_share_key(%{src: "/data/wb/site/lander/y.work"}) == "site"
  end

  test "falls back to the source dir when no workspace matches" do
    assert Nexus.Compile.compile_share_key(%{src: "/data/wb/loose/z.work"}) == "/data/wb/loose"
  end

  test "no source path (ad-hoc/SSR render) shares the default bucket" do
    assert Nexus.Compile.compile_share_key(%{kind: "rust", name: "x"}) == :shared
  end

  test "two tenants get DISTINCT keys (so the gate can fair-share between them)" do
    a = Nexus.Compile.compile_share_key(%{src: "/data/wb/tenants/acme/a.work"})
    b = Nexus.Compile.compile_share_key(%{src: "/data/wb/site/b.work"})
    refute a == b
  end
end

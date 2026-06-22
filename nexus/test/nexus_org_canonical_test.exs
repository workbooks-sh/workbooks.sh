defmodule Nexus.NexusOrgCanonicalTest do
  @moduledoc """
  Regression for wb-5wsg: the git-ingress ORG-auth gate compared a token's org to `nexus_org`, but that
  was `NEXUS_TENANT || "default"`. With NEXUS_TENANT unset, every real-org PAT (org_…) failed
  `== "default"` → 403 on every content push. nexus_org is now the CANONICAL Nexus.Auth.nexus_org
  (NEXUS_TENANT pin → founding owner's org → default), shared by the gate AND Nexus.Secrets.
  """
  use ExUnit.Case, async: false
  alias Nexus.Auth.Accounts

  setup do
    prev = System.get_env("NEXUS_TENANT")
    on_exit(fn -> if prev, do: System.put_env("NEXUS_TENANT", prev), else: System.delete_env("NEXUS_TENANT") end)
    :ok
  end

  test "NEXUS_TENANT pin wins; the gate authorizes that org, rejects foreigners, allows single-tenant" do
    System.put_env("NEXUS_TENANT", "org_pinned")
    assert Nexus.Auth.nexus_org() == "org_pinned"
    assert Nexus.GitHttp.nexus_org() == "org_pinned"

    assert Nexus.GitHttp.authorize(%{tenant: "org_pinned", user: "cli"}, true, Nexus.GitHttp.nexus_org())
    refute Nexus.GitHttp.authorize(%{tenant: "org_other"}, true, Nexus.GitHttp.nexus_org())
    assert Nexus.GitHttp.authorize(%{tenant: "anything"}, false, Nexus.GitHttp.nexus_org())
  end

  test "with NEXUS_TENANT unset, nexus_org is the founding owner's org — a real org, never default" do
    System.delete_env("NEXUS_TENANT")
    {:ok, _} = Accounts.create("owner_#{Base.encode16(:crypto.strong_rand_bytes(6))}@example.com", "supersecret", [])
    org = Nexus.Auth.nexus_org()
    assert is_binary(org) and String.starts_with?(org, "org_")
    refute org == Nexus.Store.default_tenant()

    # A PAT for the nexus's org is authorized; the OLD broken value ("default") would have been rejected.
    assert Nexus.GitHttp.authorize(%{tenant: org}, true, Nexus.GitHttp.nexus_org())
    refute Nexus.GitHttp.authorize(%{tenant: Nexus.Store.default_tenant()}, true, Nexus.GitHttp.nexus_org())
  end
end

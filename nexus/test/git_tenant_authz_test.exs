defmodule Nexus.GitTenantAuthzTest do
  @moduledoc """
  RED tests for wb-d3vh: the git transport must bind a request to the nexus's OWN org. A PAT resolves
  to its org (`ident.tenant`); on a multi-tenant nexus only a token whose tenant equals this nexus's
  org (`NEXUS_TENANT`) may touch its repos — a foreign-org token is rejected. Single-tenant/local
  (auth=None) is always allowed (one default tenant). The decision is the pure `authorize/3`.
  """
  use ExUnit.Case, async: true
  alias Nexus.GitHttp

  test "same-org token is authorized on a multi-tenant nexus" do
    assert GitHttp.authorize(%{tenant: "org-a", user: "u"}, true, "org-a")
  end

  test "foreign-org token is REJECTED on a multi-tenant nexus" do
    refute GitHttp.authorize(%{tenant: "org-b", user: "u"}, true, "org-a")
  end

  test "public/default-tenant identity is rejected on a multi-tenant nexus whose org differs" do
    refute GitHttp.authorize(%{tenant: Nexus.Store.default_tenant(), user: nil}, true, "org-a")
  end

  test "single-tenant (auth=None) is always authorized" do
    assert GitHttp.authorize(%{tenant: Nexus.Store.default_tenant(), user: "local"}, false, "org-a")
    assert GitHttp.authorize(%{tenant: "anything"}, false, Nexus.Store.default_tenant())
  end

  test "nexus_org/0 reads NEXUS_TENANT, else the default tenant" do
    prev = System.get_env("NEXUS_TENANT")

    System.put_env("NEXUS_TENANT", "org-z")
    assert GitHttp.nexus_org() == "org-z"

    System.delete_env("NEXUS_TENANT")
    assert GitHttp.nexus_org() == Nexus.Store.default_tenant()

    if prev, do: System.put_env("NEXUS_TENANT", prev)
  end
end

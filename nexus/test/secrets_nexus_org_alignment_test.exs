defmodule Nexus.SecretsNexusOrgAlignmentTest do
  @moduledoc """
  Seam 0.2 / wb-go7c: a `nexus`-scoped secret is resolved by the runtime via `Nexus.Auth.nexus_org/0`,
  so it MUST be stored under that org. This proves the alignment the platform write path now enforces
  (storing nexus-scoped secrets under nexus_org(), not the requesting admin's tenant).
  """
  use ExUnit.Case, async: false

  alias Nexus.ControlPlane.Env

  setup do
    prevk = System.get_env("WB_ENV_MASTER_KEY")
    prevt = System.get_env("NEXUS_TENANT")
    System.put_env("WB_ENV_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    nexus_org = "org_nexus_owner_#{System.unique_integer([:positive])}"
    System.put_env("NEXUS_TENANT", nexus_org)

    on_exit(fn ->
      if prevk, do: System.put_env("WB_ENV_MASTER_KEY", prevk), else: System.delete_env("WB_ENV_MASTER_KEY")
      if prevt, do: System.put_env("NEXUS_TENANT", prevt), else: System.delete_env("NEXUS_TENANT")
    end)

    {:ok, nexus_org: nexus_org}
  end

  test "the runtime resolves nexus secrets via nexus_org(); a write under any other org is stranded",
       %{nexus_org: nexus_org} do
    # this is the org Nexus.Secrets reads nexus-scoped secrets from (secrets_org/0 == nexus_org/0)
    assert Nexus.Auth.nexus_org() == nexus_org

    # the ALIGNED write (what platform.ex env_storage_org now enforces): nexus scope ⇒ nexus_org()
    {:ok, _} = Env.create(nexus_org, %{name: "RUNTIME_KEY", value: "the-real-value", scope: "nexus"})
    assert {:ok, "the-real-value"} = Env.value(nexus_org, "RUNTIME_KEY")

    # the OLD bug: the same secret written under a different (requesting-admin) tenant is invisible to
    # the runtime read, which only ever looks under nexus_org() — "saved but not applied".
    other = "org_other_admin_#{System.unique_integer([:positive])}"
    {:ok, _} = Env.create(other, %{name: "ONLY_IN_OTHER", value: "stranded", scope: "nexus"})
    assert {:error, :not_found} = Env.value(nexus_org, "ONLY_IN_OTHER")
  end
end

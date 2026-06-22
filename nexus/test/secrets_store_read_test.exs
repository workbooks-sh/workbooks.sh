defmodule Nexus.SecretsStoreReadTest do
  @moduledoc """
  The bug this guards: the dashboard WRITES nexus-scoped secrets under the logged-in org, but the
  runtime READ them under a different org (NEXUS_TENANT || "default"), so a value set in the UI never
  reached the runtime (and showed "not set"). Nexus.Secrets must read the SAME org the store wrote to.
  """
  use ExUnit.Case, async: false
  alias Nexus.ControlPlane, as: CP
  alias Nexus.ControlPlane.Env
  alias Nexus.Auth.Accounts

  @master Base.encode64(:binary.copy(<<0>>, 32))

  setup do
    System.put_env("WB_CONTROL_PLANE", "1")
    System.put_env("WB_ENV_MASTER_KEY", @master)
    CP.reset()
    prev_tenant = System.get_env("NEXUS_TENANT")

    on_exit(fn ->
      System.delete_env("WB_CONTROL_PLANE")
      System.delete_env("WB_ENV_MASTER_KEY")
      if prev_tenant, do: System.put_env("NEXUS_TENANT", prev_tenant), else: System.delete_env("NEXUS_TENANT")
    end)

    :ok
  end

  test "a secret set under an org is read back by Nexus.Secrets when that org is the secrets org" do
    org = "org_secrets_#{System.unique_integer([:positive])}"
    System.put_env("NEXUS_TENANT", org)

    {:ok, _} = Env.create(org, %{name: "CF_AIG_TOKEN", value: "cfut_test_value", scope: "nexus"})

    assert Nexus.Secrets.get("CF_AIG_TOKEN") == "cfut_test_value"
    assert Nexus.Secrets.has?("CF_AIG_TOKEN")
  end

  test "without a NEXUS_TENANT pin, Nexus.Secrets resolves the founding owner's org" do
    System.delete_env("NEXUS_TENANT")
    # Guarantee at least one owner exists; nexus_org/0 returns the earliest owner's org (the nexus IS it).
    {:ok, _} = Accounts.create("owner_#{Base.encode16(:crypto.strong_rand_bytes(6))}@example.com", "supersecret", [])
    org = Accounts.nexus_org()
    assert is_binary(org) and String.starts_with?(org, "org_")

    # A secret stored under the nexus's own org is read back with no NEXUS_TENANT pin.
    {:ok, _} = Env.create(org, %{name: "OWNER_SCOPED_SECRET", value: "v_owner", scope: "nexus"})
    assert Nexus.Secrets.get("OWNER_SCOPED_SECRET") == "v_owner"
  end
end

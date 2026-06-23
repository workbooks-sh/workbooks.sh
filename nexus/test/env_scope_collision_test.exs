defmodule Nexus.EnvScopeCollisionTest do
  @moduledoc "Seam 0.2 / wb-4fy3: (scope,name) is unique per org so value/2 can't be shadowed by a rename."
  use ExUnit.Case, async: false

  alias Nexus.ControlPlane.Env

  setup do
    prev = System.get_env("WB_ENV_MASTER_KEY")
    System.put_env("WB_ENV_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    on_exit(fn -> if prev, do: System.put_env("WB_ENV_MASTER_KEY", prev), else: System.delete_env("WB_ENV_MASTER_KEY") end)
    {:ok, org: "org_coll_#{System.unique_integer([:positive])}"}
  end

  test "create rejects a duplicate (scope,name)", %{org: org} do
    {:ok, _} = Env.create(org, %{name: "API_KEY", value: "v1", scope: "nexus"})
    assert {:error, :name_taken} = Env.create(org, %{name: "API_KEY", value: "v2", scope: "nexus"})
    # different scope, same name is allowed (distinct namespaces)
    assert {:ok, _} = Env.create(org, %{name: "API_KEY", value: "v3", scope: "user"})
  end

  test "update rejects a rename that collides within the same scope", %{org: org} do
    {:ok, a} = Env.create(org, %{name: "ALPHA", value: "v1", scope: "nexus"})
    {:ok, _b} = Env.create(org, %{name: "BETA", value: "v2", scope: "nexus"})
    # renaming BETA -> ALPHA would shadow the existing nexus ALPHA in value/2's lookup
    {:ok, b_rec} = nil_safe_find(org, "BETA")
    assert {:error, :name_taken} = Env.update(org, b_rec.id, %{name: "ALPHA"})
    # value/2 still resolves the original unambiguously
    assert {:ok, "v1"} = Env.value(org, "ALPHA")
    assert a.name == "ALPHA"
  end

  defp nil_safe_find(org, name) do
    case Enum.find(Env.list(org), &(&1.name == name)) do
      nil -> :error
      r -> {:ok, r}
    end
  end
end

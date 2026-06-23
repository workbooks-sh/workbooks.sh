defmodule Nexus.AssetTenantScopeTest do
  @moduledoc "Seam 1.2 / wb-0w41: /assets is scoped to the authenticated tenant on a multi-tenant nexus."
  use ExUnit.Case, async: true

  test "multi-tenant: only the session's own tenant may be read" do
    assert Nexus.Assets.may_serve?("orgA", "orgA", true)
    refute Nexus.Assets.may_serve?("orgA", "orgB", true)
    refute Nexus.Assets.may_serve?("default", "orgA", true)
  end

  test "single-tenant: serving is unchanged (one tenant)" do
    assert Nexus.Assets.may_serve?("default", "default", false)
    assert Nexus.Assets.may_serve?("default", "anything", false)
  end
end

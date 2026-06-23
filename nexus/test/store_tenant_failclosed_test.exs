defmodule Nexus.StoreTenantFailClosedTest do
  @moduledoc "Seam 1.2 / wb-lijn: omitting the tenant on a multi-tenant nexus fails closed (no default-partition bleed)."
  use ExUnit.Case, async: false

  defmodule DummyAdapter do
    @behaviour Nexus.Store
    def create(_r, _a, t), do: {:ok, %{tenant: t}}
    def all(_r, t), do: [%{tenant: t}]
    def count(_r, t), do: if(t == "default", do: 0, else: 1)
    def clear(_r, _t), do: :ok
  end

  setup do
    prev_adapter = Application.get_env(:nexus, :store_adapter)
    prev_auth = Application.get_env(:nexus, :auth)
    Application.put_env(:nexus, :store_adapter, DummyAdapter)
    on_exit(fn ->
      if prev_adapter, do: Application.put_env(:nexus, :store_adapter, prev_adapter), else: Application.delete_env(:nexus, :store_adapter)
      if prev_auth, do: Application.put_env(:nexus, :auth, prev_auth), else: Application.delete_env(:nexus, :auth)
    end)
    :ok
  end

  test "multi-tenant: omitting the tenant RAISES (fail closed)" do
    Application.put_env(:nexus, :auth, Nexus.Auth.Cloud)
    assert Nexus.Auth.multi?()
    assert_raise ArgumentError, ~r/omitted the tenant/, fn -> Nexus.Store.all(SomeRes) end
    assert_raise ArgumentError, fn -> Nexus.Store.count(SomeRes) end
    # explicit tenant is honored (no raise)
    assert [%{tenant: "orgA"}] = Nexus.Store.all(SomeRes, "orgA")
  end

  test "single-tenant: omitting the tenant uses default (unchanged)" do
    Application.put_env(:nexus, :auth, Nexus.Auth.None)
    refute Nexus.Auth.multi?()
    assert [%{tenant: "default"}] = Nexus.Store.all(SomeRes)
  end
end

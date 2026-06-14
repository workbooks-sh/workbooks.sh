defmodule Workbooks.TenancyPostureTest do
  @moduledoc """
  wb-2kt9 — the boot safety invariant. A hosted/cloud instance must be locked or
  multi-tenant; the unlocked single-tenant posture (which trusts the x-tenant header)
  is allowed ONLY off-cloud (desktop/dev). Pure env logic — no app boot needed.
  """
  use ExUnit.Case, async: false

  alias Workbooks.Tenancy

  setup do
    saved = for k <- ~w(WB_CONTROL_PLANE WB_CLOUD FLY_APP_NAME WB_PUBLIC_BEARER WB_TENANCY_MODE),
                do: {k, System.get_env(k)}
    for {k, _} <- saved, do: System.delete_env(k)
    on_exit(fn -> for {k, v} <- saved, do: (if v, do: System.put_env(k, v), else: System.delete_env(k)) end)
    :ok
  end

  test "off-cloud (desktop/dev): unlocked single-tenant is SAFE" do
    # no cloud signal, no lock, single-tenant — the laptop posture
    assert Tenancy.cloud_role?() == false
    assert Tenancy.safe_posture?()
    assert Tenancy.assert_safe_posture!() == :ok
  end

  test "cloud + unlocked + single-tenant is UNSAFE → raises at boot" do
    System.put_env("WB_CLOUD", "1")
    refute Tenancy.safe_posture?()
    assert_raise RuntimeError, ~r/Unsafe tenancy posture/, &Tenancy.assert_safe_posture!/0
  end

  test "cloud is made SAFE by locking (WB_PUBLIC_BEARER)" do
    System.put_env("WB_CONTROL_PLANE", "1")
    refute Tenancy.safe_posture?()
    System.put_env("WB_PUBLIC_BEARER", "secret")
    assert Tenancy.locked?()
    assert Tenancy.safe_posture?()
    assert Tenancy.assert_safe_posture!() == :ok
  end

  test "cloud is made SAFE by multi-tenant isolation" do
    System.put_env("FLY_APP_NAME", "wb-prod")    # running on Fly = cloud
    refute Tenancy.safe_posture?()
    System.put_env("WB_TENANCY_MODE", "multi")
    assert Tenancy.multi?()
    assert Tenancy.safe_posture?()
  end
end

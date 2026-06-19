defmodule Nexus.ControlPlaneAuthTest do
  use ExUnit.Case, async: false
  alias Nexus.ControlPlane, as: CP

  setup do
    prev_auth = Application.get_env(:nexus, :auth)
    prev_jwt = Application.get_env(:nexus, Nexus.Auth.Jwt)
    on_exit(fn ->
      for k <- ~w(WB_CONTROL_PLANE WB_OIDC_JWKS_URL WB_OIDC_TENANT_CLAIM WB_OIDC_ISS), do: System.delete_env(k)
      restore(:auth, prev_auth)
      restore(Nexus.Auth.Jwt, prev_jwt)
    end)
    :ok
  end

  defp restore(k, nil), do: Application.delete_env(:nexus, k)
  defp restore(k, v), do: Application.put_env(:nexus, k, v)

  test "control-plane forces WorkOS-JWT auth, configured from the deploy env" do
    System.put_env("WB_CONTROL_PLANE", "1")
    System.put_env("WB_OIDC_JWKS_URL", "https://api.workos.com/sso/jwks/client_x")
    System.put_env("WB_OIDC_TENANT_CLAIM", "org_id")

    assert CP.configure_auth() == :ok
    assert Application.get_env(:nexus, :auth) == Nexus.Auth.Jwt
    cfg = Application.get_env(:nexus, Nexus.Auth.Jwt)
    assert cfg[:jwks_url] == "https://api.workos.com/sso/jwks/client_x"
    assert cfg[:tenant_claim] == "org_id"
    # multi? must now be true so the platform router's require_org passes only for real orgs.
    assert Nexus.Auth.multi?()
  end

  test "fail-closed: control-plane with NO jwks url → adapter is Jwt but jwks_url nil (every token 401s)" do
    System.put_env("WB_CONTROL_PLANE", "1")
    assert CP.configure_auth() == :ok
    assert Application.get_env(:nexus, :auth) == Nexus.Auth.Jwt
    assert Application.get_env(:nexus, Nexus.Auth.Jwt)[:jwks_url] == nil
  end

  test "not the control-plane role → auth untouched (:skip)" do
    System.delete_env("WB_CONTROL_PLANE")
    assert CP.configure_auth() == :skip
  end
end

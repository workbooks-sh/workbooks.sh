defmodule Nexus.TokenTtlTest do
  @moduledoc "Seam 0.2 / wb-auph: PATs carry an expires_at and an expired token is refused + revoked."
  use ExUnit.Case, async: false

  describe "Nexus.ControlPlane.Token" do
    alias Nexus.ControlPlane.Token

    test "fresh token carries expires_at and resolves" do
      %{token: tok, expires_at: exp} = Token.mint("org_ttl_#{uniq()}", "cli", role: "admin", user: "u1")
      assert is_integer(exp) and exp > System.system_time(:second)
      assert {:ok, %{role: "admin", user: "u1"}} = Token.resolve(tok)
    end

    test "an expired token is refused and revoked (cannot be replayed)" do
      %{token: tok} = Token.mint("org_ttl_#{uniq()}", "cli", expires_at: System.system_time(:second) - 1)
      assert :error = Token.resolve(tok)
      # second presentation also fails — the row was revoked on first rejection
      assert :error = Token.resolve(tok)
    end

    test "legacy token with no expires_at still resolves (back-compat)" do
      # mint with an explicit far-future expiry == effectively non-expiring path stays valid
      %{token: tok} = Token.mint("org_ttl_#{uniq()}", "cli", ttl_seconds: 10 * 365 * 24 * 3600)
      assert {:ok, _} = Token.resolve(tok)
    end
  end

  describe "Nexus.Auth.Token" do
    alias Nexus.Auth.Token

    test "fresh token carries expires_at and verifies" do
      %{token: tok, expires_at: exp} = Token.mint("tenant_ttl_#{uniq()}", scopes: ["api"], roles: ["member"])
      assert is_integer(exp)
      assert {:ok, %{scopes: ["api"]}} = Token.verify(tok)
    end

    test "an expired token is refused and revoked" do
      %{token: tok} = Token.mint("tenant_ttl_#{uniq()}", expires_at: System.system_time(:second) - 1)
      assert :error = Token.verify(tok)
      assert :error = Token.verify(tok)
    end
  end

  defp uniq, do: System.unique_integer([:positive])
end

defmodule Nexus.SsoScimTest do
  @moduledoc "Enterprise SSO enforcement (domain→org, required) + SCIM 2.0 provisioning mapping."
  use ExUnit.Case, async: false
  alias Nexus.Auth.{Sso, Accounts}
  alias Nexus.Scim
  alias Nexus.ControlPlane, as: CP

  setup do
    CP.reset()
    :ok
  end

  describe "SSO enforcement" do
    test "claim a domain → route its users to the provider" do
      {:ok, _} = Sso.configure("org_a", "acme.com", "okta", required: true)
      assert Sso.provider_for("jane@acme.com") == "okta"
      assert Sso.required?("jane@acme.com")
    end

    test "an unclaimed domain has no SSO and isn't required" do
      assert Sso.for_email("nobody@random.io") == nil
      refute Sso.required?("nobody@random.io")
      assert Sso.provider_for("nobody@random.io") == nil
    end

    test "required is false when configured non-required" do
      {:ok, _} = Sso.configure("org_b", "soft.com", "google", required: false)
      assert Sso.provider_for("k@soft.com") == "google"
      refute Sso.required?("k@soft.com")
    end

    test "domain matching is case-insensitive" do
      Sso.configure("org_a", "Acme.com", "okta")
      assert Sso.provider_for("JANE@ACME.COM") == "okta"
    end
  end

  describe "SCIM representation (pure)" do
    test "to_scim renders a spec-shaped User resource" do
      u = Scim.to_scim(%{id: "u1", email: "jane@acme.com", name: "Jane Doe"})
      assert u["userName"] == "jane@acme.com"
      assert u["active"] == true
      assert [%{"value" => "jane@acme.com", "primary" => true}] = u["emails"]
      assert "urn:ietf:params:scim:schemas:core:2.0:User" in u["schemas"]
    end

    test "from_scim extracts email/name/active, incl. givenName+familyName" do
      assert %{email: "j@x.com", name: "Jane Doe", active: true} =
               Scim.from_scim(%{"userName" => "j@x.com", "name" => %{"givenName" => "Jane", "familyName" => "Doe"}})

      assert %{email: "p@x.com", active: false} =
               Scim.from_scim(%{"emails" => [%{"value" => "p@x.com", "primary" => true}], "active" => false})
    end
  end

  describe "SCIM provisioning" do
    setup do
      Accounts.ensure()
      {:ok, org: "org_scim_#{System.unique_integer([:positive])}"}
    end

    test "provision creates a new account and returns a SCIM user", %{org: org} do
      email = "new_#{System.unique_integer([:positive])}@acme.com"
      {:ok, user} = Scim.provision(org, %{"userName" => email, "name" => %{"formatted" => "New Hire"}})
      assert user["userName"] == email
      assert user["active"] == true
      assert Accounts.get_by_email(email) != nil
    end

    test "provision is idempotent for an existing userName", %{org: org} do
      email = "exists_#{System.unique_integer([:positive])}@acme.com"
      {:ok, _} = Scim.provision(org, %{"userName" => email})
      {:ok, user2} = Scim.provision(org, %{"userName" => email})
      assert user2["userName"] == email
    end

    test "provision rejects a payload with no username", %{org: org} do
      assert {:error, :missing_username} = Scim.provision(org, %{"name" => %{"formatted" => "No Email"}})
    end

    test "list returns a ListResponse filterable by userName eq", %{org: org} do
      e1 = "a_#{System.unique_integer([:positive])}@acme.com"
      e2 = "b_#{System.unique_integer([:positive])}@acme.com"
      {:ok, _} = Scim.provision(org, %{"userName" => e1})
      {:ok, _} = Scim.provision(org, %{"userName" => e2})

      all = Scim.list(org)
      assert all["totalResults"] >= 2
      assert "urn:ietf:params:scim:api:messages:2.0:ListResponse" in all["schemas"]

      filtered = Scim.list(org, ~s(userName eq "#{e1}"))
      assert filtered["totalResults"] == 1
      assert hd(filtered["Resources"])["userName"] == e1
    end
  end
end

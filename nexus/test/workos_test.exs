defmodule Nexus.WorkOSTest do
  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> System.delete_env("WORKOS_API_KEY") end)
    :ok
  end

  test "inert without an API key → [] (degrades to personal-only, never crashes)" do
    System.delete_env("WORKOS_API_KEY")
    assert Nexus.WorkOS.orgs_for_user("user_123") == []
    refute Nexus.WorkOS.configured?()
  end

  test "maps memberships → [%{id,name,role}] via an injected transport (no network)" do
    System.put_env("WORKOS_API_KEY", "sk_test")
    http = fn url ->
      cond do
        String.contains?(url, "organization_memberships") ->
          {:ok, {200, Jason.encode!(%{"data" => [%{"organization_id" => "org_a", "role" => %{"slug" => "admin"}}]})}}
        String.contains?(url, "organizations/org_a") ->
          {:ok, {200, Jason.encode!(%{"name" => "Acme"})}}
        true -> {:ok, {404, "{}"}}
      end
    end

    assert [%{id: "org_a", name: "Acme", role: "admin"}] = Nexus.WorkOS.orgs_for_user("user_123", http: http)
  end

  test "SSRF floor: a crafted user id (slash/query/control) never reaches the API → []" do
    System.put_env("WORKOS_API_KEY", "sk_test")
    boom = fn _url -> flunk("a crafted id reached the WorkOS API — SSRF/path-escape!") end
    assert Nexus.WorkOS.orgs_for_user("user/../admin", http: boom) == []
    assert Nexus.WorkOS.orgs_for_user("u?injected=1", http: boom) == []
    assert Nexus.WorkOS.orgs_for_user("u\nx", http: boom) == []
  end

  test "fail-soft on an API error → []" do
    System.put_env("WORKOS_API_KEY", "sk_test")
    http = fn _ -> {:ok, {500, "boom"}} end
    assert Nexus.WorkOS.orgs_for_user("user_123", http: http) == []
  end
end

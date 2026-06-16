defmodule OrgSecretsTest do
  @moduledoc """
  wb-xiei.2: org-provisioned agent keys. POST /api/org-secrets stores per-tenant
  (allowlisted) in Workbooks.Vars (secret); GET returns the calling tenant's keys
  only. The tenant is the Auth-verified WorkOS org (OIDC org_id -> tenant). Drives
  the router through the Auth plug with an x-tenant dev identity (no lock set).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  setup do
    System.delete_env("WB_PUBLIC_BEARER")
    System.delete_env("WB_TENANCY_MODE")
    :ok
  end

  defp req(method, path, tenant, body \\ nil) do
    c = conn(method, path, body) |> put_req_header("x-tenant", tenant)
    c = if body, do: put_req_header(c, "content-type", "application/json"), else: c
    Workbooks.Web.call(c, Workbooks.Web.init([]))
  end

  test "POST sets allowlisted keys per-tenant; GET returns only the caller's" do
    body = Jason.encode!(%{keys: %{"OPENROUTER_API_KEY" => "sk-org-A", "GEMINI_API_KEY" => "g-A", "EVIL" => "x"}})
    post = req(:post, "/api/org-secrets", "org-A", body)
    assert post.status == 200
    set = Jason.decode!(post.resp_body)["set"]
    assert "OPENROUTER_API_KEY" in set and "GEMINI_API_KEY" in set
    refute "EVIL" in set  # allowlist drops it

    get = req(:get, "/api/org-secrets", "org-A")
    assert get.status == 200
    keys = Jason.decode!(get.resp_body)["keys"]
    assert keys["OPENROUTER_API_KEY"] == "sk-org-A"
    assert keys["GEMINI_API_KEY"] == "g-A"
    refute Map.has_key?(keys, "EVIL")
  end

  test "cross-tenant isolation: org-B cannot read org-A's keys" do
    req(:post, "/api/org-secrets", "org-A", Jason.encode!(%{keys: %{"OPENROUTER_API_KEY" => "sk-A-secret"}}))
    getb = req(:get, "/api/org-secrets", "org-B")
    keys = Jason.decode!(getb.resp_body)["keys"]
    refute Map.get(keys, "OPENROUTER_API_KEY") == "sk-A-secret"
  end
end

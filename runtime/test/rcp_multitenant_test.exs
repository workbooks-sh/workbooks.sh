defmodule RcpMultiTenantTest do
  @moduledoc """
  RCP-5 (wb-19b): the shared-cloud-runtime gate. In multi-tenant mode a valid
  OIDC JWT must isolate the tenant by its `organizationId` claim, and missing /
  bad credentials must be refused with the uniform envelope. Uses the HS256
  mint+verify path (WB_AUTH_SECRET) so no live IDP is needed.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Workbooks.Auth.Guardian

  setup do
    System.put_env("WB_TENANCY_MODE", "multi")
    System.put_env("WB_AUTH_SECRET", "test-hs256-secret-please-32bytes!!")
    Guardian.install_config()

    on_exit(fn ->
      System.delete_env("WB_TENANCY_MODE")
      System.delete_env("WB_AUTH_SECRET")
      Guardian.install_config()
    end)

    :ok
  end

  defp mint(org, sub \\ "user-1") do
    {:ok, tok, _} = Guardian.encode_and_sign(sub, %{"organizationId" => org, "sessionId" => "sess-1"})
    tok
  end

  defp gate(headers) do
    conn =
      Enum.reduce(headers, conn(:get, "/instances"), fn {k, v}, c -> put_req_header(c, k, v) end)

    Workbooks.Auth.call(conn, Workbooks.Auth.init([]))
  end

  test "valid JWT scopes the tenant to organizationId" do
    conn = gate([{"authorization", "Bearer " <> mint("org-acme")}])
    refute conn.halted
    assert conn.assigns.tenant == "org-acme"
    assert conn.assigns.identity.user_id == "user-1"
    assert conn.assigns.identity.session_id == "sess-1"
  end

  test "different orgs resolve to different, isolated tenants" do
    a = gate([{"authorization", "Bearer " <> mint("org-a")}]).assigns.tenant
    b = gate([{"authorization", "Bearer " <> mint("org-b")}]).assigns.tenant
    assert a == "org-a"
    assert b == "org-b"
    assert a != b
  end

  test "no credential → tenant_required envelope (no spoofable fallback)" do
    conn = gate([])
    assert conn.halted and conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "tenant_required"
  end

  test "x-tenant header is NOT trusted in multi-tenant" do
    conn = gate([{"x-tenant", "org-evil"}])
    assert conn.halted and conn.status == 401
  end

  test "garbage token → unauthorized envelope" do
    conn = gate([{"authorization", "Bearer not.a.jwt"}])
    assert conn.halted and conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "unauthorized"
  end
end

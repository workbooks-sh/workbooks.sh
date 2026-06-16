defmodule RcpCapabilitiesTest do
  @moduledoc """
  RCP-1 (RUNTIME-CONNECT-PROTOCOL.md): the capabilities handshake is public and
  truthful, and the auth gate emits the uniform error envelope.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts Workbooks.Web.init([])

  defp call(method, path, headers \\ []) do
    conn = conn(method, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Workbooks.Web.call(conn, @opts)
  end

  describe "GET /.well-known/workbooks-runtime" do
    test "is public (no credential) and returns a valid RCP doc" do
      conn = call(:get, "/.well-known/workbooks-runtime")
      assert conn.status == 200
      doc = Jason.decode!(conn.resp_body)
      assert doc["rcp"] == "1"
      assert doc["tenancy"] in ["single", "multi"]
      assert doc["auth"]["rung"] in ["trusted", "oidc-jwt"]
      assert doc["transports"]["http"] == true
      assert is_list(doc["capabilities"]) and "workbook" in doc["capabilities"]
    end

    test "single-tenant advertises the trusted rung" do
      # default WB_TENANCY_MODE is single in test env
      doc = Workbooks.Web.Capabilities.doc()
      assert doc.tenancy == "single"
      assert doc.auth.rung == "trusted"
    end
  end

  describe "auth error envelope" do
    test "multi-tenant + no credential → uniform tenant_required envelope" do
      System.put_env("WB_TENANCY_MODE", "multi")
      on_exit(fn -> System.delete_env("WB_TENANCY_MODE") end)

      conn = call(:get, "/instances")
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "tenant_required"
      assert body["error"]["retryable"] == false
    end

    test "/health stays public even in multi-tenant" do
      System.put_env("WB_TENANCY_MODE", "multi")
      on_exit(fn -> System.delete_env("WB_TENANCY_MODE") end)
      assert call(:get, "/health").status == 200
    end
  end
end

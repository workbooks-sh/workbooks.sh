defmodule WebKeyReleaseTest do
  @moduledoc """
  Phase 1 end-to-end (wb-v3w): POST /rcp/key/:key_id through the real Workbooks.Web
  router (auth plug + dispatch). Multi-tenant so an authed JWT is a real identity
  and the dev fallback is refused — the key escrow releases ONLY on Access :allow.
  FAIL CLOSED: a denied caller gets the uniform unauthorized envelope and NO key.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Workbooks.Auth.Guardian
  alias Workbooks.Bundle.Escrow

  @opts Workbooks.Web.init([])

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
    {:ok, tok, _} = Guardian.encode_and_sign(sub, %{"organizationId" => org, "sessionId" => "s"})
    tok
  end

  defp post_key(key_id, headers) do
    conn =
      Enum.reduce(headers, conn(:post, "/rcp/key/#{key_id}"), fn {k, v}, c ->
        put_req_header(c, k, v)
      end)

    Workbooks.Web.call(conn, @opts)
  end

  test "ALLOW: an authed caller gets the escrowed key" do
    key = Workbooks.Bundle.Sealed.generate_key()
    Escrow.put("kid-allow", key)

    conn = post_key("kid-allow", [{"authorization", "Bearer " <> mint("org-acme")}])

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["key_id"] == "kid-allow"
    assert body["algo"] == "aes-256-gcm"
    assert Base.decode64!(body["key"]) == key
  end

  test "DENY: no credential → unauthorized envelope, NO key in the body" do
    key = Workbooks.Bundle.Sealed.generate_key()
    Escrow.put("kid-deny", key)

    conn = post_key("kid-deny", [])

    assert conn.status in [401]
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] in ["unauthorized", "tenant_required"]
    refute Map.has_key?(body, "key")
    refute String.contains?(conn.resp_body, Base.encode64(key))
  end

  test "an authed caller for an unknown key gets not_found, never a key" do
    conn = post_key("kid-missing", [{"authorization", "Bearer " <> mint("org-acme")}])
    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "not_found"
    refute Map.has_key?(body, "key")
  end
end

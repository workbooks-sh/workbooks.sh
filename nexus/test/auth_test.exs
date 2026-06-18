defmodule Nexus.AuthTest do
  use ExUnit.Case, async: false

  # Build a signed HS256 JWT for the Jwt adapter tests.
  defp hs256(claims, secret) do
    jwk = JOSE.JWK.from_oct(secret)
    {_, jwt} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, claims) |> JOSE.JWS.compact()
    jwt
  end

  describe "adapters" do
    test "None → everyone is the default tenant" do
      assert {:ok, %{tenant: "default"}} = Nexus.Auth.None.authenticate(%Plug.Conn{})
    end

    test "Bearer → shared token maps to a fixed tenant; wrong/absent token rejected" do
      System.put_env("NEXUS_DATA_TOKEN", "tok")
      System.put_env("NEXUS_TENANT", "acme")
      on_exit(fn -> System.delete_env("NEXUS_DATA_TOKEN"); System.delete_env("NEXUS_TENANT") end)

      ok = %Plug.Conn{req_headers: [{"authorization", "Bearer tok"}]}
      bad = %Plug.Conn{req_headers: [{"authorization", "Bearer nope"}]}

      assert {:ok, %{tenant: "acme"}} = Nexus.Auth.Bearer.authenticate(ok)
      assert {:error, _} = Nexus.Auth.Bearer.authenticate(bad)
      assert {:error, _} = Nexus.Auth.Bearer.authenticate(%Plug.Conn{req_headers: []})
    end
  end

  describe "Jwt adapter (HS256 secret — the roll-your-own / BetterAuth path)" do
    setup do
      Application.put_env(:nexus, Nexus.Auth.Jwt, secret: "shh", tenant_claim: "org", user_claim: "sub")
      on_exit(fn -> Application.delete_env(:nexus, Nexus.Auth.Jwt) end)
      :ok
    end

    test "a valid token yields the tenant + user from the configured claims" do
      jwt = hs256(%{"org" => "tenant-7", "sub" => "user-1", "exp" => System.os_time(:second) + 60}, "shh")
      conn = %Plug.Conn{req_headers: [{"authorization", "Bearer " <> jwt}]}
      assert {:ok, %{tenant: "tenant-7", user: "user-1"}} = Nexus.Auth.Jwt.authenticate(conn)
    end

    test "a token signed with the wrong secret is rejected" do
      jwt = hs256(%{"org" => "x", "exp" => System.os_time(:second) + 60}, "WRONG")
      conn = %Plug.Conn{req_headers: [{"authorization", "Bearer " <> jwt}]}
      assert {:error, _} = Nexus.Auth.Jwt.authenticate(conn)
    end

    test "an expired token is rejected" do
      jwt = hs256(%{"org" => "x", "exp" => System.os_time(:second) - 1}, "shh")
      conn = %Plug.Conn{req_headers: [{"authorization", "Bearer " <> jwt}]}
      assert {:error, _} = Nexus.Auth.Jwt.authenticate(conn)
    end

    test "a token with no tenant claim is rejected" do
      jwt = hs256(%{"sub" => "u", "exp" => System.os_time(:second) + 60}, "shh")
      conn = %Plug.Conn{req_headers: [{"authorization", "Bearer " <> jwt}]}
      assert {:error, _} = Nexus.Auth.Jwt.authenticate(conn)
    end
  end
end

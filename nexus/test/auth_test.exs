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

  # ---- Adversarial: crafts a raw unsecured (alg:none) token by hand ----
  defp b64(m), do: Base.url_encode64(m, padding: false)

  defp none_alg(claims) do
    b64(Jason.encode!(%{"alg" => "none", "typ" => "JWT"})) <>
      "." <> b64(Jason.encode!(claims)) <> "."
  end

  describe "ADVERSARIAL: signature-algorithm attacks" do
    setup do
      Application.put_env(:nexus, Nexus.Auth.Jwt, secret: "shh", tenant_claim: "org")
      on_exit(fn -> Application.delete_env(:nexus, Nexus.Auth.Jwt) end)
      :ok
    end

    test "alg:none token is rejected (no bypass of signature check)" do
      jwt = none_alg(%{"org" => "victim", "exp" => System.os_time(:second) + 60})
      assert {:error, _} = Nexus.Auth.Jwt.verify(jwt)
    end

    test "RS256->HS256 confusion: an HS256 token is rejected when only RS256 is allowed" do
      # The JWKS/RS256 path calls verify_strict(jwk, ["RS256"], jwt); an attacker who HMAC-signs
      # with the public key as the secret still presents alg:HS256, which is NOT in the allow-list.
      rs = JOSE.JWK.generate_key({:rsa, 2048})
      {_, pub_map} = JOSE.JWK.to_public(rs) |> JOSE.JWK.to_map()
      hs = JOSE.JWK.from_oct("attacker-secret")
      {_, forged} = JOSE.JWT.sign(hs, %{"alg" => "HS256"}, %{"org" => "victim"}) |> JOSE.JWS.compact()

      assert {false, _, _} = JOSE.JWT.verify_strict(JOSE.JWK.from_map(pub_map), ["RS256"], forged)
    end
  end

  describe "ADVERSARIAL: tenant claim injection / type confusion" do
    setup do
      Application.put_env(:nexus, Nexus.Auth.Jwt, secret: "shh", tenant_claim: "org")
      on_exit(fn -> Application.delete_env(:nexus, Nexus.Auth.Jwt) end)
      :ok
    end

    defp conn_for(org_value) do
      jwt = hs256(%{"org" => org_value, "exp" => System.os_time(:second) + 60}, "shh")
      %Plug.Conn{req_headers: [{"authorization", "Bearer " <> jwt}]}
    end

    test "non-binary tenant claims (number, null, array, object) are rejected" do
      for bad <- [42, nil, true, ["a", "b"], %{"x" => 1}] do
        assert {:error, :no_tenant_claim} = Nexus.Auth.Jwt.authenticate(conn_for(bad)),
               "tenant=#{inspect(bad)} should be rejected"
      end
    end

    test "an empty-string tenant claim is rejected" do
      assert {:error, :no_tenant_claim} = Nexus.Auth.Jwt.authenticate(conn_for(""))
    end

    test "a weird-but-valid string tenant survives but cannot escape its partition" do
      weird = "tenant'; DROP TABLE r_item;-- /*<svg>*/"
      assert {:ok, %{tenant: ^weird}} = Nexus.Auth.Jwt.authenticate(conn_for(weird))
      # the string is bound, never interpolated: it is its own isolated partition with no rows.
      mod =
        "resource WidgetA do\n  n :text\nend\n"
        |> WorkCore.Literate.parse() |> Enum.find(&(&1.type == :code)) |> Nexus.Resource.compile()

      Nexus.Store.create(mod, %{n: "real"}, "real-tenant")
      assert Nexus.Store.all(mod, weird) == []
      assert Nexus.Store.count(mod, weird) == 0
    end
  end

  describe "ADVERSARIAL: exp / iss tampering" do
    setup do
      Application.put_env(:nexus, Nexus.Auth.Jwt, secret: "shh", tenant_claim: "org", issuer: "https://good.example")
      on_exit(fn -> Application.delete_env(:nexus, Nexus.Auth.Jwt) end)
      :ok
    end

    test "wrong issuer is rejected when an issuer is configured" do
      jwt = hs256(%{"org" => "x", "iss" => "https://evil.example", "exp" => System.os_time(:second) + 60}, "shh")
      assert {:error, _} = Nexus.Auth.Jwt.verify(jwt)
    end

    test "correct issuer passes" do
      jwt = hs256(%{"org" => "x", "iss" => "https://good.example", "exp" => System.os_time(:second) + 60}, "shh")
      assert {:ok, %{"org" => "x"}} = Nexus.Auth.Jwt.verify(jwt)
    end

    test "a tampered payload (mutated body, original signature) is rejected" do
      jwt = hs256(%{"org" => "alice", "iss" => "https://good.example", "exp" => System.os_time(:second) + 60}, "shh")
      [h, _p, sig] = String.split(jwt, ".")
      forged_payload = b64(Jason.encode!(%{"org" => "admin", "iss" => "https://good.example", "exp" => System.os_time(:second) + 60}))
      tampered = h <> "." <> forged_payload <> "." <> sig
      assert {:error, _} = Nexus.Auth.Jwt.verify(tampered)
    end
  end

  describe "ADVERSARIAL: Bearer timing-safe compare + config" do
    test "Bearer uses a constant-time compare (no plain ==)" do
      # white-box: the source must not compare the raw header with == anymore.
      src = File.read!("lib/auth.ex")
      assert src =~ "Plug.Crypto.secure_compare"
      refute src =~ ~r/get_req_header\(conn, "authorization"\) == /
    end

    test "missing/empty NEXUS_DATA_TOKEN never authenticates (fails closed)" do
      System.delete_env("NEXUS_DATA_TOKEN")
      conn = %Plug.Conn{req_headers: [{"authorization", "Bearer "}]}
      assert {:error, :no_token_configured} = Nexus.Auth.Bearer.authenticate(conn)
      System.put_env("NEXUS_DATA_TOKEN", "")
      on_exit(fn -> System.delete_env("NEXUS_DATA_TOKEN") end)
      assert {:error, :no_token_configured} = Nexus.Auth.Bearer.authenticate(conn)
    end
  end

  describe "ADVERSARIAL: header edge cases" do
    setup do
      Application.put_env(:nexus, Nexus.Auth.Jwt, secret: "shh", tenant_claim: "org")
      on_exit(fn -> Application.delete_env(:nexus, Nexus.Auth.Jwt) end)
      :ok
    end

    test "lowercase 'bearer ' scheme is not accepted (scheme is case-sensitive by design)" do
      jwt = hs256(%{"org" => "x", "exp" => System.os_time(:second) + 60}, "shh")
      conn = %Plug.Conn{req_headers: [{"authorization", "bearer " <> jwt}]}
      assert {:error, _} = Nexus.Auth.Jwt.authenticate(conn)
    end

    test "multiple Authorization headers do not authenticate (single-header match only)" do
      jwt = hs256(%{"org" => "x", "exp" => System.os_time(:second) + 60}, "shh")
      conn = %Plug.Conn{req_headers: [{"authorization", "Bearer " <> jwt}, {"authorization", "Bearer " <> jwt}]}
      assert {:error, _} = Nexus.Auth.Jwt.authenticate(conn)
    end

    test "a very long garbage token is rejected without crashing (DoS-resistant)" do
      conn = %Plug.Conn{req_headers: [{"authorization", "Bearer " <> String.duplicate("A", 200_000)}]}
      assert {:error, _} = Nexus.Auth.Jwt.authenticate(conn)
    end
  end

  describe "ADVERSARIAL: JWKS hardening (https-only, crash-safe, key miss)" do
    test "a non-https jwks_url is refused (no cleartext key fetch / MITM key-swap)" do
      Application.put_env(:nexus, Nexus.Auth.Jwt, jwks_url: "http://evil.example/jwks.json", tenant_claim: "org")
      on_exit(fn -> Application.delete_env(:nexus, Nexus.Auth.Jwt) end)
      # any RS256-shaped token: jwks_key bails on the http scheme before any network call.
      rs = JOSE.JWK.generate_key({:rsa, 2048})
      {_, jwt} = JOSE.JWT.sign(rs, %{"alg" => "RS256", "kid" => "k1"}, %{"org" => "x"}) |> JOSE.JWS.compact()
      conn = %Plug.Conn{req_headers: [{"authorization", "Bearer " <> jwt}]}
      assert {:error, _} = Nexus.Auth.Jwt.authenticate(conn)
    end
  end

end

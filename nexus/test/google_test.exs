defmodule Nexus.GoogleTest do
  use ExUnit.Case, async: true

  # A throwaway RSA key, generated once for the suite, used to sign + verify the assertion.
  setup_all do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, pem} = JOSE.JWK.to_pem(jwk)
    {:ok, jwk: jwk, pem: pem}
  end

  test "unconfigured (no secrets, no opts) → {:skip, _}, never an error or a network call" do
    assert {:skip, _} = Nexus.Google.access_token("admin@example.com", ["scope"])
  end

  test "signed_assertion produces an RS256 JWT-bearer with the right impersonation claims", %{jwk: jwk, pem: pem} do
    {:ok, jwt} =
      Nexus.Google.signed_assertion(
        "user@customer.com",
        "https://www.googleapis.com/auth/admin.directory.user openid",
        email: "sa@proj.iam.gserviceaccount.com",
        private_key: pem
      )

    {true, %JOSE.JWT{fields: claims}, _} = JOSE.JWT.verify(jwk, jwt)
    assert claims["iss"] == "sa@proj.iam.gserviceaccount.com"
    assert claims["sub"] == "user@customer.com"
    assert claims["scope"] =~ "admin.directory.user"
    assert claims["aud"] == "https://oauth2.googleapis.com/token"
    assert claims["exp"] > claims["iat"]
  end

  test "access_token exchanges the assertion and normalises the bundle (http injected)", %{pem: pem} do
    http = fn :post, "https://oauth2.googleapis.com/token", _h, body ->
      # the form must carry the jwt-bearer grant + a non-empty assertion
      decoded = URI.decode_query(body)
      assert decoded["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer"
      assert is_binary(decoded["assertion"]) and decoded["assertion"] != ""
      {:ok, {200, Jason.encode!(%{"access_token" => "ya29.test", "expires_in" => 3599})}}
    end

    assert {:ok, %{access: "ya29.test", expires_at: exp}} =
             Nexus.Google.access_token("user@customer.com", ["s1", "s2"],
               email: "sa@proj.iam.gserviceaccount.com",
               private_key: pem,
               http: http
             )

    assert is_integer(exp) and exp > System.os_time(:second)
  end

  test "a non-2xx token response surfaces an error, not a crash", %{pem: pem} do
    http = fn :post, _url, _h, _body ->
      {:ok, {400, Jason.encode!(%{"error" => "unauthorized_client"})}}
    end

    assert {:error, {:token_http, 400, %{"error" => "unauthorized_client"}}} =
             Nexus.Google.access_token("user@customer.com", "s",
               email: "sa@x", private_key: pem, http: http)
  end

  test "scopes accept a list or a space-joined string", %{jwk: jwk, pem: pem} do
    opts = [email: "sa@x", private_key: pem]
    {:ok, a} = Nexus.Google.signed_assertion("u@c", ["a", "b"], opts)
    {:ok, b} = Nexus.Google.signed_assertion("u@c", "a b", opts)
    {true, %JOSE.JWT{fields: ca}, _} = JOSE.JWT.verify(jwk, a)
    {true, %JOSE.JWT{fields: cb}, _} = JOSE.JWT.verify(jwk, b)
    assert ca["scope"] == "a b"
    assert cb["scope"] == "a b"
  end
end

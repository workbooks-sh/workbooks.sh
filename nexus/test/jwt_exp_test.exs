defmodule Nexus.Auth.JwtExpTest do
  @moduledoc "Seam 1.1 / wb-bri2: a JWT with no `exp` claim is rejected (absence ⇒ deny, JWT-BCP RFC 8725)."
  use ExUnit.Case, async: true

  @secret "test-hs256-secret-value"

  defp sign(claims) do
    jwk = JOSE.JWK.from_oct(@secret)
    {_, jwt} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, claims) |> JOSE.JWS.compact()
    jwt
  end

  test "a token WITHOUT exp is rejected" do
    jwt = sign(%{"sub" => "u1", "tenant" => "org"})
    assert {:error, :invalid_token} = Nexus.Auth.Jwt.verify(jwt, secret: @secret)
  end

  test "a token with a future exp is accepted" do
    jwt = sign(%{"sub" => "u1", "exp" => System.os_time(:second) + 3600})
    assert {:ok, %{"sub" => "u1"}} = Nexus.Auth.Jwt.verify(jwt, secret: @secret)
  end

  test "a token with a past exp is rejected" do
    jwt = sign(%{"sub" => "u1", "exp" => System.os_time(:second) - 1})
    assert {:error, :invalid_token} = Nexus.Auth.Jwt.verify(jwt, secret: @secret)
  end
end

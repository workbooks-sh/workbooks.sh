defmodule Workbooks.OIDCTest do
  @moduledoc """
  Pins the generic OIDC/JWKS verifier (wb-wejt) — works for ANY RS256 IdP
  (WorkOS/Clerk/Auth0). Deterministic via JOSE-generated fixture keys; no live IdP.
  """
  use ExUnit.Case, async: true
  alias Workbooks.OIDC

  defp signed(jwk, kid, claims) do
    {_, t} = JOSE.JWT.sign(jwk, %{"alg" => "RS256", "kid" => kid}, claims) |> JOSE.JWS.compact()
    t
  end

  defp jwks_of(jwk, kid) do
    {_, m} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    %{"keys" => [Map.merge(m, %{"kid" => kid, "use" => "sig", "alg" => "RS256"})]}
  end

  defp future, do: System.system_time(:second) + 3600

  setup do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {:ok, jwk: jwk, jwks: jwks_of(jwk, "k1")}
  end

  test "valid RS256 token → {:ok, org_id-as-tenant}", %{jwk: jwk, jwks: jwks} do
    assert OIDC.verify_token(signed(jwk, "k1", %{"org_id" => "org_ABC", "exp" => future()}), jwks) == {:ok, "org_ABC"}
  end

  test "token signed by a DIFFERENT key → :error", %{jwk: jwk} do
    token = signed(jwk, "k1", %{"org_id" => "x", "exp" => future()})
    other = JOSE.JWK.generate_key({:rsa, 2048})
    assert OIDC.verify_token(token, jwks_of(other, "k1")) == :error
  end

  test "expired token → :error", %{jwk: jwk, jwks: jwks} do
    assert OIDC.verify_token(signed(jwk, "k1", %{"org_id" => "x", "exp" => 1}), jwks) == :error
  end

  test "unknown kid → :error", %{jwk: jwk, jwks: jwks} do
    assert OIDC.verify_token(signed(jwk, "nope", %{"org_id" => "x", "exp" => future()}), jwks) == :error
  end

  test "organization_id and sub also map to tenant (provider-agnostic)", %{jwk: jwk, jwks: jwks} do
    assert OIDC.verify_token(signed(jwk, "k1", %{"organization_id" => "org_2", "exp" => future()}), jwks) == {:ok, "org_2"}
    assert OIDC.verify_token(signed(jwk, "k1", %{"sub" => "user_9", "exp" => future()}), jwks) == {:ok, "user_9"}
  end

  test "garbage token → :error (never raises)", %{jwks: jwks} do
    assert OIDC.verify_token("not.a.jwt", jwks) == :error
    assert OIDC.verify_token("", jwks) == :error
  end

  # JWT alg-confusion attacks — the verifier pins RS256, so neither lands.
  test "rejects an alg:none (unsigned) token", %{jwks: jwks} do
    hdr = Base.url_encode64(Jason.encode!(%{"alg" => "none", "kid" => "k1"}), padding: false)
    pl = Base.url_encode64(Jason.encode!(%{"org_id" => "x", "exp" => future()}), padding: false)
    assert OIDC.verify_token("#{hdr}.#{pl}.", jwks) == :error
  end

  test "rejects an HS256 token (alg outside the RS256 whitelist — key-confusion)", %{jwks: jwks} do
    oct = JOSE.JWK.from_oct("attacker-secret")
    {_, tok} = JOSE.JWT.sign(oct, %{"alg" => "HS256", "kid" => "k1"}, %{"org_id" => "x", "exp" => future()}) |> JOSE.JWS.compact()
    assert OIDC.verify_token(tok, jwks) == :error
  end
end

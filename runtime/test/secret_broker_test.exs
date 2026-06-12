defmodule Workbooks.SecretBrokerTest do
  use ExUnit.Case, async: false
  alias Workbooks.SecretBroker

  test "sign uses the host-held secret; the guest gets the SIGNATURE, never the key" do
    t = "t-#{System.unique_integer([:positive])}"
    assert :ok = SecretBroker.register(t, "apikey", "super-secret-value")

    assert {:ok, sig} = SecretBroker.sign(t, "apikey", "payload")
    # the signature equals HMAC-SHA256(secret, data) computed independently — proves the host applied the key
    assert sig == :crypto.mac(:hmac, :sha256, "super-secret-value", "payload")
    # and it's a real 32-byte SHA256 MAC, not the secret echoed back
    assert byte_size(sig) == 32
    refute sig =~ "super-secret"
  end

  test "NO READ — the module exposes no way to retrieve a secret's value" do
    # The security property: only register/2..3 + sign/3 are public; there is no get/read of the value.
    exports = Workbooks.SecretBroker.__info__(:functions) |> Keyword.keys() |> Enum.uniq()
    refute :get in exports
    refute :read in exports
    refute :value in exports
    refute :fetch in exports
    assert :sign in exports
  end

  test "unknown secret is denied" do
    t = "t-#{System.unique_integer([:positive])}"
    assert {:error, :unknown_secret} = SecretBroker.sign(t, "nope", "data")
  end

  test "TENANT ISOLATION — a tenant cannot sign with another tenant's secret" do
    a = "a-#{System.unique_integer([:positive])}"
    b = "b-#{System.unique_integer([:positive])}"
    assert :ok = SecretBroker.register(a, "k", "alice-key")
    # b never registered "k" -> b cannot use a's secret
    assert {:error, :unknown_secret} = SecretBroker.sign(b, "k", "data")
    # a signs with its own
    assert {:ok, _} = SecretBroker.sign(a, "k", "data")
  end

  test "REVOCATION — a revoked tenant cannot sign" do
    t = "t-#{System.unique_integer([:positive])}"
    assert :ok = SecretBroker.register(t, "k", "key")
    assert {:ok, _} = SecretBroker.sign(t, "k", "data")

    assert :ok = Workbooks.Revocation.revoke(t)
    assert {:error, :revoked} = SecretBroker.sign(t, "k", "data")
    assert :ok = Workbooks.Revocation.unrevoke(t)
    assert {:ok, _} = SecretBroker.sign(t, "k", "data")
  end
end

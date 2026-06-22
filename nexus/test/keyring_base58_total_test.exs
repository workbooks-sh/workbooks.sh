defmodule Nexus.KeyringBase58TotalTest do
  @moduledoc """
  RED tests for the base58-decode totality fix (the bonus defect surfaced tracing the verify chain).

  Today `Nexus.Keyring.base58_decode/1` (keyring.ex:108-114) uses `Map.fetch!(@b58_index, c)`, which
  RAISES on any non-base58 character — so `public_from_did/1` is not total and a forged DID crashes the
  reader. Post-fix, `base58_decode/1` must return `{:ok, binary} | :error` (total over arbitrary input)
  and `public_from_did/1` must adapt to that result, yielding `:error` (→ verify=false) on garbage.

  Helper the implementer must provide (named exactly as the spec proposes):
    * Nexus.Keyring.base58_decode(str) :: {:ok, binary} | :error  (encode path untouched)
  """
  use ExUnit.Case
  alias Nexus.Keyring

  describe "Keyring.base58_decode/1 totality" do
    test "unknown chars (0, O, I, l are outside the bitcoin alphabet) return :error, never raise" do
      assert Keyring.base58_decode("z0OIl") == :error
    end

    test "a valid encode round-trips to {:ok, original}" do
      bin = :crypto.strong_rand_bytes(34)
      encoded = Keyring.base58_encode(bin)
      assert Keyring.base58_decode(encoded) == {:ok, bin}
    end

    test "the empty string decodes to {:ok, <<>>}" do
      assert Keyring.base58_decode("") == {:ok, <<>>}
    end
  end

  describe "Keyring.public_from_did/1 over hostile input" do
    test "a did:key with garbage base58 body returns :error instead of raising" do
      assert Keyring.public_from_did("did:key:z0OIl0OIl") == :error
    end

    test "a well-formed did:key still round-trips to {:ok, pub}" do
      pub = Keyring.generate().public
      assert Keyring.public_from_did(Keyring.did(pub)) == {:ok, pub}
    end
  end
end

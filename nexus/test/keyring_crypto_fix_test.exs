defmodule Nexus.KeyringCryptoFixTest do
  @moduledoc """
  RED tests for wb-qbq8 — the verify path must be TOTAL: malformed but binary input
  returns false (or :error), never raises.

  Helpers the implementer must provide (per extractToLib):
    * `Keyring.base58_decode/1 :: String.t() -> {:ok, binary()} | :error`
      (total — any non-alphabet char yields :error, never raises)
    * `Keyring.base58_decode!/1 :: String.t() -> binary()`
      (bang variant for internal/round-trip callers that want the raw binary)
    * `Keyring.verify/3` guard tightened to byte_size(public)==32 and
      byte_size(signature)==64, so wrong-length binaries hit the `false` catch-all.

  These fail against current code:
    * `base58_decode/1` uses `Map.fetch!` -> KeyError on junk chars (and returns a
      raw binary, not an {:ok,_} tuple).
    * `public_from_did/1` leaks that KeyError.
    * `verify/3` lets wrong-length binaries reach :crypto -> ErlangError (badarg).
  """
  use ExUnit.Case, async: true

  alias Nexus.Keyring

  describe "base58_decode/1 is total" do
    test "non-alphabet chars yield :error, never raise" do
      # 0 O I l are explicitly excluded from the base58 alphabet.
      assert Keyring.base58_decode("0OIl") == :error
      assert Keyring.base58_decode("hello world!") == :error
    end

    test "valid base58 round-trips via base58_decode!/1 (raw binary bang form)" do
      raw = <<0xED, 0x01, 7, 7, 7, 7>>
      enc = Keyring.base58_encode(raw)
      assert Keyring.base58_decode!(enc) == raw
    end

    test "valid base58 also decodes via the total tuple form" do
      raw = <<1, 2, 3, 4, 5>>
      enc = Keyring.base58_encode(raw)
      assert Keyring.base58_decode(enc) == {:ok, raw}
    end
  end

  describe "public_from_did/1 is total" do
    test "a DID with a non-base58 char returns :error, never raises (KeyError today)" do
      assert Keyring.public_from_did("did:key:z0OIl") == :error
    end

    test "still rejects junk / wrong-prefix DIDs" do
      assert Keyring.public_from_did("not-a-did") == :error
      assert Keyring.public_from_did("did:key:zABC") == :error
    end

    test "a genuine DID still round-trips to its public key" do
      kp = Keyring.generate()
      did = Keyring.did(kp.public)
      assert Keyring.public_from_did(did) == {:ok, kp.public}
    end
  end

  describe "verify/3 is a total boolean over arbitrary binaries" do
    test "wrong-length key and sig return false, never raise (ErlangError today)" do
      assert Keyring.verify(<<1, 2, 3>>, "m", <<4, 5, 6>>) == false
    end

    test "31-byte key returns false" do
      assert Keyring.verify(:binary.copy(<<0>>, 31), "m", :binary.copy(<<0>>, 64)) == false
    end

    test "63-byte sig returns false" do
      assert Keyring.verify(:binary.copy(<<0>>, 32), "m", :binary.copy(<<0>>, 63)) == false
    end

    test "a valid 32/64 keypair signature still verifies" do
      kp = Keyring.generate()
      sig = Keyring.sign(kp.private, "hello")
      assert byte_size(kp.public) == 32
      assert byte_size(sig) == 64
      assert Keyring.verify(kp.public, "hello", sig)
    end
  end
end

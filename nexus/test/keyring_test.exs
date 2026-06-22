defmodule Nexus.KeyringTest do
  use ExUnit.Case, async: true
  alias Nexus.Keyring

  test "generates 32-byte ed25519 keypairs" do
    kp = Keyring.generate()
    assert byte_size(kp.public) == 32
    assert byte_size(kp.private) == 32
  end

  test "sign/verify round-trips and rejects tampering" do
    kp = Keyring.generate()
    sig = Keyring.sign(kp.private, "the snapshot")
    assert byte_size(sig) == 64
    assert Keyring.verify(kp.public, "the snapshot", sig)
    refute Keyring.verify(kp.public, "a different snapshot", sig)

    other = Keyring.generate()
    refute Keyring.verify(other.public, "the snapshot", sig)
  end

  test "did:key encodes ed25519 and round-trips back to the public key" do
    kp = Keyring.generate()
    pub = kp.public
    did = Keyring.did(pub)
    assert String.starts_with?(did, "did:key:z")
    assert {:ok, ^pub} = Keyring.public_from_did(did)
  end

  test "did:key is the W3C/Radicle multicodec form (0xed01 prefix)" do
    kp = Keyring.generate()
    "did:key:z" <> b58 = Keyring.did(kp.public)
    assert {:ok, <<0xED, 0x01, pub::binary-size(32)>>} = Keyring.base58_decode(b58)
    assert pub == kp.public
  end

  test "public_from_did rejects junk" do
    assert :error = Keyring.public_from_did("did:key:znope")
    assert :error = Keyring.public_from_did("not-a-did")
  end

  test "base58 round-trips arbitrary bytes incl. leading zeros" do
    for bin <- [<<0>>, <<0, 0, 1, 2, 3>>, :crypto.strong_rand_bytes(33), <<>>] do
      assert Keyring.base58_decode(Keyring.base58_encode(bin)) == {:ok, bin}
    end
  end

  test "fingerprint is stable and short" do
    kp = Keyring.generate()
    fp = Keyring.fingerprint(kp.public)
    assert byte_size(fp) == 8
    assert fp == Keyring.fingerprint(kp.public)
  end

  test "load_or_create persists and reloads the same identity" do
    path = Path.join(System.tmp_dir!(), "wb-keyring-test-#{System.unique_integer([:positive])}.key")
    on_exit(fn -> File.rm(path) end)

    a = Keyring.load_or_create(path)
    b = Keyring.load_or_create(path)
    assert a.private == b.private
    assert a.public == b.public

    # the recomputed public key actually verifies signatures
    sig = Keyring.sign(b.private, "x")
    assert Keyring.verify(a.public, "x", sig)
  end
end

defmodule Nexus.KeyringTotalDecodeTest do
  @moduledoc """
  RED tests for wb-9mid (keyring half): `Nexus.Keyring.base58_decode/1` must be TOTAL —
  `{:ok, binary} | :error` — never raising on malformed input. Today it does
  `Map.fetch!(@b58_index, c)` (keyring.ex:111) which RAISES KeyError on any non-base58
  character, and `public_from_did/2` (keyring.ex:38) pattern-matches the RAW decode, so a
  malformed `did:key:z…` propagates the raise instead of returning `:error`.

  Post-fix contract the implementer must provide:

      Nexus.Keyring.base58_decode(str :: binary) :: {:ok, binary} | :error
      # round-trips encode/3, preserves leading-zero bytes, :error on any char ∉ base58 alphabet

      Nexus.Keyring.public_from_did(did :: binary) :: {:ok, binary} | :error
      # threads the :error from base58_decode through instead of raising
  """
  use ExUnit.Case, async: true
  alias Nexus.Keyring

  test "base58_decode/1 is TOTAL: non-base58 chars return :error (was a raise)" do
    # `0`, `O`, `I`, `l` are the four chars deliberately absent from the Bitcoin base58 alphabet.
    assert Keyring.base58_decode("0OIl") == :error
    # Other clearly-non-alphabet chars must also be :error, not crash.
    assert Keyring.base58_decode("!!!") == :error
    assert Keyring.base58_decode("hello world") == :error
  end

  test "base58_decode/1 round-trips encode/1 incl. leading-zero bytes" do
    bin = :crypto.strong_rand_bytes(32)
    assert Keyring.base58_decode(Keyring.base58_encode(bin)) == {:ok, bin}

    # leading zero bytes must survive the round-trip (they map to leading '1's)
    leading_zeros = <<0, 0, 0, 7, 9, 11>>
    assert Keyring.base58_decode(Keyring.base58_encode(leading_zeros)) == {:ok, leading_zeros}

    # empty -> empty
    assert Keyring.base58_decode(Keyring.base58_encode(<<>>)) == {:ok, <<>>}
  end

  test "base58_decode/1 of a real did body decodes to the multicodec+pubkey" do
    kp = Keyring.generate()
    "did:key:z" <> body = Keyring.did(kp.public)
    assert {:ok, <<0xED, 0x01, pub::binary-size(32)>>} = Keyring.base58_decode(body)
    assert pub == kp.public
  end

  test "public_from_did/1 of a MALFORMED did returns :error (does not raise)" do
    # 'l' and '0' are not in the base58 alphabet -> decode must be :error, threaded out as :error.
    assert Keyring.public_from_did("did:key:z0OIl") == :error
    assert Keyring.public_from_did("did:key:znot valid base58!") == :error
    # well-formed-prefix but garbage body of wrong length -> :error, not a crash
    assert Keyring.public_from_did("did:key:z111") == :error
  end

  test "public_from_did/1 round-trips a real did" do
    kp = Keyring.generate()
    assert {:ok, pub} = Keyring.public_from_did(Keyring.did(kp.public))
    assert pub == kp.public
  end
end

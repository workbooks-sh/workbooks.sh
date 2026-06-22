defmodule Nexus.LedgerCryptoFixTest do
  @moduledoc """
  RED test for wb-talp amplifier — `Ledger.decode/1` must be the EXACT inverse of
  `Ledger.encode/1`, so a signed value containing "\\n"/"=" round-trips intact and
  CANNOT spawn a spurious new field.

  Fails against current code: decode/1 re-splits body lines on "=" and Map.new's them,
  so a value like "x\\ntokens=999" injects a real `tokens => "999"` field (and truncates
  `note`), making encode|>decode lossy/asymmetric.
  """
  use ExUnit.Case, async: true

  alias Nexus.Attest
  alias Nexus.Keyring
  alias Nexus.Ledger

  test "encode |> decode is the identity on fields (no field injection from \\n/= in a value)" do
    kp = Keyring.generate()
    att = Attest.sign(kp, %{"run" => "r1", "note" => "x\ntokens=999"})

    dec = Ledger.decode(Ledger.encode(att))

    assert dec.fields == att.fields,
           "decode injected a spurious field from a signed value containing \\n="

    assert dec.did == att.did
    assert dec.sig == att.sig
  end

  test "the round-tripped attestation still verifies" do
    kp = Keyring.generate()
    att = Attest.sign(kp, %{"run" => "r1", "note" => "x\ntokens=999"})

    dec = Ledger.decode(Ledger.encode(att))
    assert Attest.verify(dec, dec.did)
  end

  test "plain attestations still round-trip losslessly" do
    kp = Keyring.generate()
    att = Attest.sign(kp, %{"run" => "r1", "model" => "m", "tokens_out" => "12"})

    dec = Ledger.decode(Ledger.encode(att))
    assert dec.fields == att.fields
    assert Attest.verify(dec, dec.did)
  end
end
